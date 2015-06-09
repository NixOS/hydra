#include <atomic>
#include <condition_variable>
#include <iostream>
#include <map>
#include <memory>
#include <thread>

#include <pqxx/pqxx>

#include "build-result.hh"
#include "build-remote.hh"
#include "sync.hh"
#include "pool.hh"

#include "store-api.hh"
#include "derivations.hh"
#include "shared.hh"
#include "globals.hh"

using namespace nix;


template <class C, class V>
bool has(const C & c, const V & v)
{
    return c.find(v) != c.end();
}


std::mutex exitRequestMutex;
std::condition_variable exitRequest;
std::atomic<bool> exitRequested(false);

static std::atomic_int _int(0);

void sigintHandler(int signo)
{
    _int = 1;
}


void signalThread()
{
    struct sigaction act;
    act.sa_handler = sigintHandler;
    sigemptyset(&act.sa_mask);
    act.sa_flags = 0;
    if (sigaction(SIGINT, &act, 0))
        throw SysError("installing handler for SIGINT");

    while (true) {
        sleep(1000000);
        if (_int) break;
    }

    {
        std::lock_guard<std::mutex> lock(exitRequestMutex);
        exitRequested = true;
    }
    exitRequest.notify_all();
}


typedef enum {
    bsSuccess = 0,
    bsFailed = 1,
    bsDepFailed = 2,
    bsAborted = 3,
    bsFailedWithOutput = 6,
} BuildStatus;


typedef enum {
    bssSuccess = 0,
    bssFailed = 1,
    bssAborted = 4,
    bssBusy = 100, // not stored
} BuildStepStatus;


struct Connection : pqxx::connection
{
    Connection() : pqxx::connection("dbname=hydra") { };
};


typedef unsigned int BuildID;


struct Step;


struct Build
{
    typedef std::shared_ptr<Build> ptr;
    typedef std::weak_ptr<Build> wptr;

    BuildID id;
    Path drvPath;
    std::map<string, Path> outputs;
    std::string fullJobName;

    std::shared_ptr<Step> toplevel;

    bool finishedInDB;

    Build() : finishedInDB(false) { }

    ~Build()
    {
        printMsg(lvlError, format("destroying build %1%") % id);
    }
};


struct Step
{
    typedef std::shared_ptr<Step> ptr;
    typedef std::weak_ptr<Step> wptr;

    Path drvPath;
    Derivation drv;

    struct State
    {
        /* The build steps on which this step depends. */
        std::set<Step::ptr> deps;

        /* The build steps that depend on this step. */
        std::vector<Step::wptr> rdeps;

        /* Builds that have this step as the top-level derivation. */
        std::vector<Build::wptr> builds;
    };

    Sync<State> state;

    std::atomic_bool destroyed;

    Step() : destroyed(false) { }

    ~Step()
    {
        printMsg(lvlError, format("destroying step %1%") % drvPath);
    }
};


struct Machine
{
    typedef std::shared_ptr<Machine> ptr;

    std::string sshName, sshKey;
    std::set<std::string> systemTypes, supportedFeatures, mandatoryFeatures;
    unsigned int maxJobs = 1;
    float speedFactor = 1.0;

    Sync<unsigned int> currentJobs;

    Machine()
    {
        auto currentJobs_(currentJobs.lock());
        *currentJobs_ = 0;
    }
};


/* A RAII helper that manages the currentJobs field of Machine
   objects. */
struct MachineReservation
{
    typedef std::shared_ptr<MachineReservation> ptr;
    Machine::ptr machine;
    MachineReservation(Machine::ptr machine) : machine(machine)
    {
        auto currentJobs_(machine->currentJobs.lock());
        (*currentJobs_)++;
    }
    ~MachineReservation()
    {
        auto currentJobs_(machine->currentJobs.lock());
        if (*currentJobs_ > 0) (*currentJobs_)--;
    }
};


class State
{
private:

    Path hydraData, logDir;

    /* CV for waking up the queue. */
    std::condition_variable queueMonitorWakeup;
    std::mutex queueMonitorMutex;

    /* The queued builds. */
    typedef std::map<BuildID, Build::ptr> Builds;
    Sync<Builds> builds;

    /* All active or pending build steps (i.e. dependencies of the
       queued builds). Note that these are weak pointers. Steps are
       kept alive by being reachable from Builds or by being in
       progress. */
    typedef std::map<Path, Step::wptr> Steps;
    Sync<Steps> steps;

    /* Build steps that have no unbuilt dependencies. */
    typedef std::list<Step::wptr> Runnable;
    Sync<Runnable> runnable;

    std::condition_variable_any runnableWakeup;

    /* CV for waking up the dispatcher. */
    std::condition_variable dispatcherWakeup;
    std::mutex dispatcherMutex;

    /* PostgreSQL connection pool. */
    Pool<Connection> dbPool;

    /* The build machines. */
    typedef std::list<Machine::ptr> Machines;
    Sync<Machines> machines;

    /* The currently active builder threads. FIXME: We could re-use
       these, but since they're fairly long-running, it's probably not
       worth it. */
    // std::vector<std::thread> builderThreads;

public:
    State();

    ~State();

    void loadMachines();

    void clearBusy(time_t stopTime);

    int createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
        BuildStepStatus status, const std::string & errorMsg = "", BuildID propagatedFrom = 0);

    void finishBuildStep(pqxx::work & txn, time_t startTime, time_t stopTime, BuildID buildId, int stepNr,
        BuildStepStatus status, const string & errorMsg = "", BuildID propagatedFrom = 0);

    void updateBuild(pqxx::work & txn, Build::ptr build, BuildStatus status);

    void queueMonitor();

    void getQueuedBuilds(std::shared_ptr<StoreAPI> store);

    Step::ptr createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath,
        std::set<Step::ptr> & newRunnable);

    void destroyStep(Step::ptr step, bool proceed);

    /* Get the builds that depend on the given step. */
    std::set<Build::ptr> getDependentBuilds(Step::ptr step);

    void makeRunnable(Step::ptr step);

    /* The thread that selects and starts runnable builds. */
    void dispatcher();

    void wakeDispatcher();

    MachineReservation::ptr findMachine(Step::ptr step);

    void builder(Step::ptr step, MachineReservation::ptr reservation);

    void doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step,
        Machine::ptr machine);

    void markSucceededBuild(pqxx::work & txn, Build::ptr build,
        const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime);

    void run();
};


State::State()
{
    hydraData = getEnv("HYDRA_DATA");
    if (hydraData == "") throw Error("$HYDRA_DATA must be set");

    logDir = canonPath(hydraData + "/build-logs");
}


State::~State()
{
    try {
        printMsg(lvlError, "clearing active builds / build steps...");
        clearBusy(time(0));
    } catch (...) {
        ignoreException();
    }
}


void State::loadMachines()
{
    Path machinesFile = getEnv("NIX_REMOTE_SYSTEMS", "/etc/nix/machines");

    Machines newMachines;

    if (pathExists(machinesFile)) {

        for (auto line : tokenizeString<Strings>(readFile(machinesFile), "\n")) {
            line = trim(string(line, 0, line.find('#')));
            auto tokens = tokenizeString<std::vector<std::string>>(line);
            if (tokens.size() < 3) continue;
            tokens.resize(7);

            auto machine = std::make_shared<Machine>();
            machine->sshName = tokens[0];
            machine->systemTypes = tokenizeString<StringSet>(tokens[1], ",");
            machine->sshKey = tokens[2];
            if (tokens[3] != "")
                string2Int(tokens[3], machine->maxJobs);
            else
                machine->maxJobs = 1;
            machine->speedFactor = atof(tokens[4].c_str());
            machine->supportedFeatures = tokenizeString<StringSet>(tokens[5], ",");
            machine->mandatoryFeatures = tokenizeString<StringSet>(tokens[6], ",");
            newMachines.push_back(machine);
        }

    } else {
        auto machine = std::make_shared<Machine>();
        machine->sshName = "localhost";
        machine->systemTypes = StringSet({settings.thisSystem});
        if (settings.thisSystem == "x86_64-linux")
            machine->systemTypes.insert("i686-linux");
        machine->maxJobs = settings.maxBuildJobs;
        newMachines.push_back(machine);
    }

    auto machines_(machines.lock());
    *machines_ = newMachines;
}


void State::clearBusy(time_t stopTime)
{
    auto conn(dbPool.get());
    pqxx::work txn(*conn);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, stopTime = $2 where busy = 1")
        ((int) bssAborted)
        (stopTime, stopTime != 0).exec();
    txn.exec("update Builds set busy = 0 where finished = 0 and busy = 1");
    txn.commit();
}


int State::createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
    BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    auto res = txn.parameterized("select max(stepnr) from BuildSteps where build = $1")(build->id).exec();
    int stepNr = res[0][0].is_null() ? 1 : res[0][0].as<int>() + 1;

    txn.parameterized
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, startTime, system, status, propagatedFrom, errorMsg, stopTime) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)")
        (build->id)(stepNr)(0)(step->drvPath)(status == bssBusy ? 1 : 0)(startTime)(step->drv.platform)
        ((int) status, status != bssBusy)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (startTime, status != bssBusy).exec();

    for (auto & output : step->drv.outputs)
        txn.parameterized
            ("insert into BuildStepOutputs (build, stepnr, name, path) values ($1, $2, $3, $4)")
            (build->id)(stepNr)(output.first)(output.second.path).exec();

    return stepNr;
}


void State::finishBuildStep(pqxx::work & txn, time_t startTime, time_t stopTime, BuildID buildId, int stepNr,
    BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    assert(startTime);
    assert(stopTime);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, propagatedFrom = $4, errorMsg = $5, startTime = $6, stopTime = $7 where build = $2 and stepnr = $3")
        ((int) status)(buildId)(stepNr)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (startTime)(stopTime).exec();
}


void State::queueMonitor()
{
    auto store = openStore(); // FIXME: pool

    while (!exitRequested) {
        getQueuedBuilds(store);

        {
            std::unique_lock<std::mutex> lock(queueMonitorMutex);
            queueMonitorWakeup.wait_for(lock, std::chrono::seconds(5));
        }
    }

    printMsg(lvlError, "queue monitor exits");
}


void State::getQueuedBuilds(std::shared_ptr<StoreAPI> store)
{
    printMsg(lvlError, "checking the queue...");

    auto conn(dbPool.get());

#if 0
    {
        auto runnable_(runnable.lock());
        auto builds_(builds.lock());
        auto steps_(steps.lock());
        printMsg(lvlError, format("%1% builds, %2% steps, %3% runnable steps")
            % builds_->size()
            % steps_->size()
            % runnable_->size());
    }
#endif

    /* Grab the queued builds from the database, but don't process
       them yet (since we don't want a long-running transaction). */
    std::list<Build::ptr> newBuilds; // FIXME: use queue

    {
        pqxx::work txn(*conn);

        // FIXME: query only builds with ID higher than the previous
        // highest.
        auto res = txn.exec("select * from Builds where finished = 0 order by id");

        auto builds_(builds.lock());

        for (auto const & row : res) {
            BuildID id = row["id"].as<BuildID>();
            if (has(*builds_, id)) continue;

            auto build = std::make_shared<Build>();
            build->id = id;
            build->drvPath = row["drvPath"].as<string>();
            build->fullJobName = row["project"].as<string>() + ":" + row["jobset"].as<string>() + ":" + row["job"].as<string>();

            newBuilds.push_back(build);
        }
    }

    /* Now instantiate build steps for each new build. The builder
       threads can start building the runnable build steps right away,
       even while we're still processing other new builds. */
    for (auto & build : newBuilds) {
        // FIXME: remove build from newBuilds to ensure quick destruction
        // FIXME: exception handling

        printMsg(lvlInfo, format("loading build %1% (%2%)") % build->id % build->fullJobName);

        if (!store->isValidPath(build->drvPath)) {
            /* Derivation has been GC'ed prematurely. */
            printMsg(lvlInfo, format("aborting GC'ed build %1%") % build->id);
            pqxx::work txn(*conn);
            txn.parameterized
                ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $3, errorMsg = $4 where id = $1")
                (build->id)
                ((int) bsAborted)
                (time(0))
                ("derivation was garbage-collected prior to build").exec();
            txn.commit();
            continue;
        }

        std::set<Step::ptr> newRunnable;
        Step::ptr step = createStep(store, build->drvPath, newRunnable);

        /* If we didn't get a step, it means the step's outputs are
           all valid. So we mark this as a finished, cached build. */
        if (!step) {
            Derivation drv = readDerivation(build->drvPath);
            BuildResult res = getBuildResult(store, drv);

            printMsg(lvlInfo, format("cached build %1%") % build->id);

            pqxx::work txn(*conn);
            time_t now = time(0);
            markSucceededBuild(txn, build, res, true, now, now);
            txn.commit();

            continue;
        }

        /* Note: if we exit this scope prior to this, the build and
           all newly created steps are destroyed. */

        {
            auto builds_(builds.lock());
            auto step_(step->state.lock());
            (*builds_)[build->id] = build;
            step_->builds.push_back(build);
            build->toplevel = step;
        }

        printMsg(lvlInfo, format("added build %1% (top-level step %2%, %3% new runnable steps)")
            % build->id % step->drvPath % newRunnable.size());

        /* Prior to this, the build is not visible to
           getDependentBuilds().  Now it is, so the build can be
           failed if a dependency fails. (It can't succeed right away
           because its top-level is not runnable yet). */

        /* Add the new runnable build steps to ‘runnable’ and wake up
           the builder threads. */
        for (auto & r : newRunnable)
            makeRunnable(r);
    }
}


Step::ptr State::createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath,
    std::set<Step::ptr> & newRunnable)
{
    /* Check if the requested step already exists. */
    {
        auto steps_(steps.lock());
        auto prev = steps_->find(drvPath);
        if (prev != steps_->end()) {
            auto step = prev->second.lock();
            /* Since ‘step’ is a strong pointer, the referred Step
               object won't be deleted after this. */
            if (step) return step;
            steps_->erase(drvPath); // remove stale entry
        }
    }

    printMsg(lvlInfo, format("considering derivation ‘%1%’") % drvPath);

    auto step = std::make_shared<Step>();
    step->drvPath = drvPath;
    step->drv = readDerivation(drvPath);

    /* Are all outputs valid? */
    bool valid = true;
    for (auto & i : step->drv.outputs) {
        if (!store->isValidPath(i.second.path)) {
            valid = false;
            break;
        }
    }

    // FIXME: check whether all outputs are in the binary cache.
    if (valid) return 0;

    /* No, we need to build. */
    printMsg(lvlInfo, format("creating build step ‘%1%’") % drvPath);

    /* Create steps for the dependencies. */
    bool hasDeps = false;
    for (auto & i : step->drv.inputDrvs) {
        Step::ptr dep = createStep(store, i.first, newRunnable);
        if (dep) {
            hasDeps = true;
            auto step_(step->state.lock());
            auto dep_(dep->state.lock());
            step_->deps.insert(dep);
            dep_->rdeps.push_back(step);
        }
    }

    {
        auto steps_(steps.lock());
        assert(steps_->find(drvPath) == steps_->end());
        (*steps_)[drvPath] = step;
    }

    if (!hasDeps) newRunnable.insert(step);

    return step;
}


void State::destroyStep(Step::ptr step, bool proceed)
{
    if (step->destroyed) return;
    step->destroyed = true;

    printMsg(lvlInfo, format("destroying build step ‘%1%’") % step->drvPath);

    {
        auto steps_(steps.lock());
        steps_->erase(step->drvPath);
    }

    std::vector<Step::wptr> rdeps;

    {
        auto step_(step->state.lock());
        rdeps = step_->rdeps;

        /* Sanity checks. */
        for (auto & build_ : step_->builds) {
            auto build = build_.lock();
            if (!build) continue;
            assert(build->drvPath == step->drvPath);
            assert(build->finishedInDB);
        }
    }

    for (auto & rdep_ : rdeps) {
        auto rdep = rdep_.lock();
        if (!rdep) continue;
        bool runnable = false;
        {
            auto rdep_(rdep->state.lock());
            assert(has(rdep_->deps, step));
            rdep_->deps.erase(step);
            if (rdep_->deps.empty()) runnable = true;
        }
        if (proceed) {
            /* If this rdep has no other dependencies, then we can now
               build it. */
            if (runnable)
                makeRunnable(rdep);
        } else
            /* If ‘step’ failed or was cancelled, then delete all
               dependent steps as well. */
            destroyStep(rdep, false);
    }
}


std::set<Build::ptr> State::getDependentBuilds(Step::ptr step)
{
    std::set<Step::ptr> done;
    std::set<Build::ptr> res;

    std::function<void(Step::ptr)> visit;

    visit = [&](Step::ptr step) {
        if (has(done, step)) return;
        done.insert(step);

        std::vector<Step::wptr> rdeps;

        {
            auto step_(step->state.lock());

            for (auto & build : step_->builds) {
                auto build_ = build.lock();
                if (build_) res.insert(build_);
            }

            /* Make a copy of rdeps so that we don't hold the lock for
               very long. */
            rdeps = step_->rdeps;
        }

        for (auto & rdep : rdeps) {
            auto rdep_ = rdep.lock();
            if (rdep_) visit(rdep_);
        }
    };

    visit(step);

    return res;
}


void State::makeRunnable(Step::ptr step)
{
    printMsg(lvlInfo, format("step ‘%1%’ is now runnable") % step->drvPath);

    {
        auto step_(step->state.lock());
        assert(step_->deps.empty());
    }

    {
        auto runnable_(runnable.lock());
        runnable_->push_back(step);
    }

    wakeDispatcher();
}


void State::dispatcher()
{
    while (!exitRequested) {
        printMsg(lvlError, "dispatcher woken up");

        {
            auto runnable_(runnable.lock());
            printMsg(lvlError, format("%1% runnable builds") % runnable_->size());

            /* FIXME: we're holding the runnable lock too long
               here. This could be more efficient. */

            for (auto i = runnable_->begin(); i != runnable_->end(); ) {
                auto step = i->lock();

                /* Delete dead steps. */
                if (!step) {
                    i = runnable_->erase(i);
                    continue;
                }

                auto reservation = findMachine(step);
                if (!reservation) {
                    printMsg(lvlError, format("cannot execute step ‘%1%’ right now") % step->drvPath);
                    ++i;
                    continue;
                }

                printMsg(lvlInfo, format("WOOHOO: starting step ‘%1%’ on machine ‘%2%’")
                    % step->drvPath % reservation->machine->sshName);
                i = runnable_->erase(i);

                auto builderThread = std::thread(&State::builder, this, step, reservation);
                builderThread.detach(); // FIXME?
            }
        }

        /* Sleep until we're woken up (either because a runnable build
           is added, or because a build finishes). */
        {
            std::unique_lock<std::mutex> lock(dispatcherMutex);
            dispatcherWakeup.wait(lock);
        }
    }

    printMsg(lvlError, "dispatcher exits");
}


void State::wakeDispatcher()
{
    { std::lock_guard<std::mutex> lock(dispatcherMutex); } // barrier
    dispatcherWakeup.notify_all();
}


MachineReservation::ptr State::findMachine(Step::ptr step)
{
    auto machines_(machines.lock());

    for (auto & machine : *machines_) {
        if (!has(machine->systemTypes, step->drv.platform)) continue;
        // FIXME: check features
        {
            auto currentJobs_(machine->currentJobs.lock());
            if (*currentJobs_ >= machine->maxJobs) continue;
        }
        return std::make_shared<MachineReservation>(machine);
    }

    /* FIXME: distinguish between permanent failures (a matching
       machine doesn't exist) and temporary failures (a matching
       machine is not available). */

    return 0;
}


void State::builder(Step::ptr step, MachineReservation::ptr reservation)
{
    try {
        auto store = openStore(); // FIXME: pool
        doBuildStep(store, step, reservation->machine);
    } catch (std::exception & e) {
        printMsg(lvlError, format("build thread for ‘%1%’: %2%") % step->drvPath % e.what());
        // FIXME: put step back in runnable and retry
    }

    /* Release the machine and wake up the dispatcher. */
    assert(reservation.unique());
    reservation = 0;
    wakeDispatcher();

    printMsg(lvlError, "builder exits");
}


void State::doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step,
    Machine::ptr machine)
{
    /* There can be any number of builds in the database that depend
       on this derivation. Arbitrarily pick one (though preferring a
       build of which this is the top-level derivation) for the
       purpose of creating build steps. We could create a build step
       record for every build, but that could be very expensive
       (e.g. a stdenv derivation can be a dependency of tens of
       thousands of builds), so we don't. */
    Build::ptr build;

    {
        auto dependents = getDependentBuilds(step);

        if (dependents.empty()) {
            /* Apparently all builds that depend on this derivation
               are gone (e.g. cancelled). So don't bother. (This is
               very unlikely to happen, because normally Steps are
               only kept alive by being reachable from a
               Build). FIXME: what if a new Build gets a reference to
               this step? */
            printMsg(lvlInfo, format("cancelling build step ‘%1%’") % step->drvPath);
            destroyStep(step, false);
            return;
        }

        for (auto build2 : dependents)
            if (build2->drvPath == step->drvPath) { build = build2; break; }

        if (!build) build = *dependents.begin();

        printMsg(lvlInfo, format("performing build step ‘%1%’ (needed by %2% builds)") % step->drvPath % dependents.size());
    }

    /* Create a build step record indicating that we started
       building. Also, mark the selected build as busy. */
    auto conn(dbPool.get());
    RemoteResult result;
    result.startTime = time(0);
    int stepNr;
    {
        pqxx::work txn(*conn);
        stepNr = createBuildStep(txn, result.startTime, build, step, bssBusy);

        txn.parameterized("update Builds set busy = 1 where id = $1")(build->id).exec();

        txn.commit();
    }

    try {
        buildRemote(store, machine->sshName, machine->sshKey, step->drvPath, step->drv, logDir, result);
    } catch (Error & e) {
        result.status = RemoteResult::rrMiscFailure;
        result.errorMsg = e.msg();
        printMsg(lvlError, format("ERROR: %1%") % e.msg());
        abort();
    }

    if (!result.stopTime) result.stopTime = time(0);

    BuildResult res;
    if (result.status == RemoteResult::rrSuccess) res = getBuildResult(store, step->drv);

    // FIXME: handle failed-with-output

    /* Remove this step. After this, incoming builds that depend on
       drvPath will either see that the output paths exist, or will
       create a new build step for drvPath. The latter is fine - it
       won't conflict with this one, because we're removing it. In any
       case, the set of dependent builds for ‘step’ can't increase
       anymore because ‘step’ is no longer visible to createStep(). */
    {
        auto steps_(steps.lock());
        steps_->erase(step->drvPath);
    }

    /* Get the final set of dependent builds. */
    auto dependents = getDependentBuilds(step);

    std::set<Build::ptr> direct;
    {
        auto step_(step->state.lock());
        for (auto & build : step_->builds) {
            auto build_ = build.lock();
            if (build_) direct.insert(build_);
        }
    }

    /* Update the database. */
    {
        pqxx::work txn(*conn);

        if (result.status == RemoteResult::rrSuccess) {

            finishBuildStep(txn, result.startTime, result.stopTime, build->id, stepNr, bssSuccess);

            /* Mark all builds of which this derivation is the top
               level as succeeded. */
            for (auto build2 : direct)
                markSucceededBuild(txn, build2, res, false, result.startTime, result.stopTime);

        } else {
            /* Create failed build steps for every build that depends
               on this. */
            finishBuildStep(txn, result.startTime, result.stopTime, build->id, stepNr, bssFailed, result.errorMsg);

            for (auto build2 : dependents) {
                if (build == build2) continue;
                createBuildStep(txn, result.stopTime, build2, step, bssFailed, result.errorMsg, build->id);
            }

            /* Mark all builds that depend on this derivation as failed. */
            for (auto build2 : dependents) {
                printMsg(lvlError, format("marking build %1% as failed") % build2->id);
                txn.parameterized
                    ("update Builds set finished = 1, busy = 0, isCachedBuild = 0, buildStatus = $2, startTime = $3, stopTime = $4 where id = $1")
                    (build2->id)
                    ((int) (build2->drvPath == step->drvPath ? bsFailed : bsDepFailed))
                    (result.startTime)
                    (result.stopTime).exec();
                build2->finishedInDB = true; // FIXME: txn might fail
            }
        }

        txn.commit();
    }

    /* In case of success, destroy all Build objects of which ‘step’
       is the top-level derivation. In case of failure, destroy all
       dependent Build objects. Any Steps not referenced by other
       Builds will be destroyed as well. */
    for (auto build2 : dependents)
        if (build2->toplevel == step || result.status != RemoteResult::rrSuccess) {
            auto builds_(builds.lock());
            builds_->erase(build2->id);
        }

    /* Remove the step from the graph. In case of success, make
       dependent build steps runnable if they have no other
       dependencies. */
    destroyStep(step, result.status == RemoteResult::rrSuccess);
}


void State::markSucceededBuild(pqxx::work & txn, Build::ptr build,
    const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime)
{
    printMsg(lvlError, format("marking build %1% as succeeded") % build->id);

    txn.parameterized
        ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $4, size = $5, closureSize = $6, releaseName = $7, isCachedBuild = $8 where id = $1")
        (build->id)
        ((int) bsSuccess)
        (startTime)
        (stopTime)
        (res.size)
        (res.closureSize)
        (res.releaseName, res.releaseName != "")
        (isCachedBuild ? 1 : 0).exec();

    unsigned int productNr = 1;
    for (auto & product : res.products) {
        txn.parameterized
            ("insert into BuildProducts (build, productnr, type, subtype, fileSize, sha1hash, sha256hash, path, name, defaultPath) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)")
            (build->id)
            (productNr++)
            (product.type)
            (product.subtype)
            (product.fileSize, product.isRegular)
            (printHash(product.sha1hash), product.isRegular)
            (printHash(product.sha256hash), product.isRegular)
            (product.path)
            (product.name)
            (product.defaultPath).exec();
    }

    build->finishedInDB = true; // FIXME: txn might fail
}


void State::run()
{
    clearBusy(0);

    loadMachines();

    auto queueMonitorThread = std::thread(&State::queueMonitor, this);

    auto dispatcherThread = std::thread(&State::dispatcher, this);

    /* Wait for SIGINT. */
    {
        std::unique_lock<std::mutex> lock(exitRequestMutex);
        while (!exitRequested)
            exitRequest.wait(lock);
    }

    printMsg(lvlError, "exiting...");

    /* Shut down the various threads. */
    { std::lock_guard<std::mutex> lock(queueMonitorMutex); } // barrier
    queueMonitorWakeup.notify_all();
    queueMonitorThread.join();

    wakeDispatcher();
    dispatcherThread.join();

    printMsg(lvlError, format("psql connections = %1%") % dbPool.count());
}


int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();

        std::thread(signalThread).detach();

        /* Ignore signals. This is inherited by the other threads. */
        sigset_t set;
        sigemptyset(&set);
        sigaddset(&set, SIGHUP);
        sigaddset(&set, SIGINT);
        sigaddset(&set, SIGTERM);
        sigprocmask(SIG_BLOCK, &set, NULL);

        settings.buildVerbosity = lvlVomit;
        settings.useSubstitutes = false;

        /* FIXME: need some locking to prevent multiple instances of
           hydra-queue-runner. */
        State state;
        state.run();
    });
}

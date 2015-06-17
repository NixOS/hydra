#include <atomic>
#include <condition_variable>
#include <iostream>
#include <map>
#include <memory>
#include <thread>
#include <cmath>
#include <chrono>

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


const int maxTries = 5;
const int retryInterval = 60; // seconds
const float retryBackoff = 3.0;


typedef std::chrono::time_point<std::chrono::system_clock> system_time;


template <class C, class V>
bool has(const C & c, const V & v)
{
    return c.find(v) != c.end();
}


typedef enum {
    bsSuccess = 0,
    bsFailed = 1,
    bsDepFailed = 2,
    bsAborted = 3,
    bsFailedWithOutput = 6,
    bsTimedOut = 7,
    bsUnsupported = 9,
} BuildStatus;


typedef enum {
    bssSuccess = 0,
    bssFailed = 1,
    bssAborted = 4,
    bssTimedOut = 7,
    bssUnsupported = 9,
    bssBusy = 100, // not stored
} BuildStepStatus;


struct Connection : pqxx::connection
{
    Connection() : pqxx::connection(getFlags()) { };

    string getFlags()
    {
        string s = getEnv("HYDRA_DBI", "dbi:Pg:dbname=hydra;");
        string prefix = "dbi:Pg:";
        if (string(s, 0, prefix.size()) != prefix)
            throw Error("$HYDRA_DBI does not denote a PostgreSQL database");
        return concatStringsSep(" ", tokenizeString<Strings>(string(s, prefix.size()), ";"));
    }
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
    unsigned int maxSilentTime, buildTimeout;

    std::shared_ptr<Step> toplevel;

    bool finishedInDB;

    Build() : finishedInDB(false) { }

    ~Build()
    {
        printMsg(lvlDebug, format("destroying build %1%") % id);
    }
};


struct Step
{
    typedef std::shared_ptr<Step> ptr;
    typedef std::weak_ptr<Step> wptr;

    Path drvPath;
    Derivation drv;
    std::set<std::string> requiredSystemFeatures;

    struct State
    {
        /* The build steps on which this step depends. */
        std::set<Step::ptr> deps;

        /* The build steps that depend on this step. */
        std::vector<Step::wptr> rdeps;

        /* Builds that have this step as the top-level derivation. */
        std::vector<Build::wptr> builds;

        /* Number of times we've tried this step. */
        unsigned int tries = 0;

        /* Point in time after which the step can be retried. */
        system_time after;
    };

    Sync<State> state;

    std::atomic_bool destroyed;

    Step() : destroyed(false) { }

    ~Step() { }
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

    bool supportsStep(Step::ptr step)
    {
        if (systemTypes.find(step->drv.platform) == systemTypes.end()) return false;
        for (auto & f : mandatoryFeatures)
            if (step->requiredSystemFeatures.find(f) == step->requiredSystemFeatures.end()) return false;
        for (auto & f : step->requiredSystemFeatures)
            if (supportedFeatures.find(f) == supportedFeatures.end()) return false;
        return true;
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

    /* Various stats. */
    std::atomic<unsigned int> nrRetries;
    std::atomic<unsigned int> maxNrRetries;
    std::atomic<unsigned int> nrQueueWakeups;
    std::atomic<unsigned int> nrDispatcherWakeups;

public:
    State();

    ~State();

    void loadMachines();

    void clearBusy(time_t stopTime);

    int createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
        const std::string & machine, BuildStepStatus status, const std::string & errorMsg = "",
        BuildID propagatedFrom = 0);

    void finishBuildStep(pqxx::work & txn, time_t startTime, time_t stopTime, BuildID buildId, int stepNr,
        const std::string & machine, BuildStepStatus status, const string & errorMsg = "",
        BuildID propagatedFrom = 0);

    void updateBuild(pqxx::work & txn, Build::ptr build, BuildStatus status);

    void queueMonitor();

    void queueMonitorLoop();

    void getQueuedBuilds(Connection & conn, std::shared_ptr<StoreAPI> store, unsigned int & lastBuildId);

    void removeCancelledBuilds(Connection & conn);

    Step::ptr createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath,
        std::set<Step::ptr> & newSteps, std::set<Step::ptr> & newRunnable);

    void destroyStep(Step::ptr step, bool proceed);

    /* Get the builds that depend on the given step. */
    std::set<Build::ptr> getDependentBuilds(Step::ptr step);

    void makeRunnable(Step::ptr step);

    /* The thread that selects and starts runnable builds. */
    void dispatcher();

    void wakeDispatcher();

    MachineReservation::ptr findMachine(Step::ptr step);

    void builder(Step::ptr step, MachineReservation::ptr reservation);

    /* Perform the given build step. Return true if the step is to be
       retried. */
    bool doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step,
        Machine::ptr machine);

    void markSucceededBuild(pqxx::work & txn, Build::ptr build,
        const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime);

    bool checkCachedFailure(Step::ptr step, Connection & conn);

    void dumpStatus();

    void run();
};


State::State()
{
    nrRetries = maxNrRetries = nrQueueWakeups = nrDispatcherWakeups = 0;

    hydraData = getEnv("HYDRA_DATA");
    if (hydraData == "") throw Error("$HYDRA_DATA must be set");

    logDir = canonPath(hydraData + "/build-logs");
}


State::~State()
{
    try {
        printMsg(lvlInfo, "clearing active builds / build steps...");
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
            for (auto & f : machine->mandatoryFeatures)
                machine->supportedFeatures.insert(f);
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
    const std::string & machine, BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    /* Acquire an exclusive lock on BuildSteps to ensure that we don't
       race with other threads creating a step of the same build. */
    txn.exec("lock table BuildSteps in exclusive mode");

    auto res = txn.parameterized("select max(stepnr) from BuildSteps where build = $1")(build->id).exec();
    int stepNr = res[0][0].is_null() ? 1 : res[0][0].as<int>() + 1;

    txn.parameterized
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, startTime, system, status, propagatedFrom, errorMsg, stopTime, machine) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)")
        (build->id)(stepNr)(0)(step->drvPath)(status == bssBusy ? 1 : 0)
        (startTime, startTime != 0)
        (step->drv.platform)
        ((int) status, status != bssBusy)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (startTime, startTime != 0 && status != bssBusy)
        (machine).exec();

    for (auto & output : step->drv.outputs)
        txn.parameterized
            ("insert into BuildStepOutputs (build, stepnr, name, path) values ($1, $2, $3, $4)")
            (build->id)(stepNr)(output.first)(output.second.path).exec();

    return stepNr;
}


void State::finishBuildStep(pqxx::work & txn, time_t startTime, time_t stopTime, BuildID buildId, int stepNr,
    const std::string & machine, BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    assert(startTime);
    assert(stopTime);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, propagatedFrom = $4, errorMsg = $5, startTime = $6, stopTime = $7, machine = $8 where build = $2 and stepnr = $3")
        ((int) status)(buildId)(stepNr)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (startTime)(stopTime)
        (machine, machine != "").exec();
}


void State::queueMonitor()
{
    while (true) {
        try {
            queueMonitorLoop();
        } catch (std::exception & e) {
            printMsg(lvlError, format("queue monitor: %1%") % e.what());
            sleep(10); // probably a DB problem, so don't retry right away
        }
    }
}


void State::queueMonitorLoop()
{
    auto conn(dbPool.get());

    struct receiver : public pqxx::notification_receiver
    {
        bool status = false;
        receiver(pqxx::connection_base & c, const std::string & channel)
            : pqxx::notification_receiver(c, channel) { }
        void operator() (const string & payload, int pid) override
        {
            status = true;
        };
        bool get() {
            bool b = status;
            status = false;
            return b;
        }
    };

    receiver buildsAdded(*conn, "builds_added");
    receiver buildsRestarted(*conn, "builds_restarted");
    receiver buildsCancelled(*conn, "builds_cancelled");
    receiver dumpStatus(*conn, "dump_status");

    auto store = openStore(); // FIXME: pool

    unsigned int lastBuildId = 0;

    while (true) {
        getQueuedBuilds(*conn, store, lastBuildId);

        /* Sleep until we get notification from the database about an
           event. */
        conn->await_notification();
        nrQueueWakeups++;

        if (buildsAdded.get())
            printMsg(lvlTalkative, "got notification: new builds added to the queue");
        if (buildsRestarted.get()) {
            printMsg(lvlTalkative, "got notification: builds restarted");
            lastBuildId = 0; // check all builds
        }
        if (buildsCancelled.get()) {
            printMsg(lvlTalkative, "got notification: builds cancelled");
            removeCancelledBuilds(*conn);
        }

        if (dumpStatus.get())
            State::dumpStatus();
    }
}


void State::getQueuedBuilds(Connection & conn, std::shared_ptr<StoreAPI> store, unsigned int & lastBuildId)
{
    printMsg(lvlInfo, format("checking the queue for builds > %1%...") % lastBuildId);

    /* Grab the queued builds from the database, but don't process
       them yet (since we don't want a long-running transaction). */
    std::multimap<Path, Build::ptr> newBuilds;

    {
        pqxx::work txn(conn);

        auto res = txn.parameterized("select id, project, jobset, job, drvPath, maxsilent, timeout from Builds where id > $1 and finished = 0 order by id")(lastBuildId).exec();

        for (auto const & row : res) {
            auto builds_(builds.lock());
            BuildID id = row["id"].as<BuildID>();
            if (id > lastBuildId) lastBuildId = id;
            if (has(*builds_, id)) continue;

            auto build = std::make_shared<Build>();
            build->id = id;
            build->drvPath = row["drvPath"].as<string>();
            build->fullJobName = row["project"].as<string>() + ":" + row["jobset"].as<string>() + ":" + row["job"].as<string>();
            build->maxSilentTime = row["maxsilent"].as<int>();
            build->buildTimeout = row["timeout"].as<int>();

            newBuilds.emplace(std::make_pair(build->drvPath, build));
        }
    }

    std::set<Step::ptr> newRunnable;
    unsigned int nrAdded;
    std::function<void(Build::ptr)> createBuild;

    createBuild = [&](Build::ptr build) {
        printMsg(lvlTalkative, format("loading build %1% (%2%)") % build->id % build->fullJobName);
        nrAdded++;

        if (!store->isValidPath(build->drvPath)) {
            /* Derivation has been GC'ed prematurely. */
            printMsg(lvlError, format("aborting GC'ed build %1%") % build->id);
            pqxx::work txn(conn);
            txn.parameterized
                ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $3, errorMsg = $4 where id = $1")
                (build->id)
                ((int) bsAborted)
                (time(0))
                ("derivation was garbage-collected prior to build").exec();
            txn.commit();
            return;
        }

        std::set<Step::ptr> newSteps;
        Step::ptr step = createStep(store, build->drvPath, newSteps, newRunnable);

        /* Some of the new steps may be the top level of builds that
           we haven't processed yet. So do them now. This ensures that
           if build A depends on build B with top-level step X, then X
           will be "accounted" to B in doBuildStep(). */
        for (auto & r : newSteps) {
            while (true) {
                auto i = newBuilds.find(r->drvPath);
                if (i == newBuilds.end()) break;
                Build::ptr b = i->second;
                newBuilds.erase(i);
                createBuild(b);
            }
        }

        /* If we didn't get a step, it means the step's outputs are
           all valid. So we mark this as a finished, cached build. */
        if (!step) {
            Derivation drv = readDerivation(build->drvPath);
            BuildResult res = getBuildResult(store, drv);

            printMsg(lvlInfo, format("marking build %1% as cached successful") % build->id);

            pqxx::work txn(conn);
            time_t now = time(0);
            markSucceededBuild(txn, build, res, true, now, now);
            txn.commit();

            return;
        }

        /* If any step has an unsupported system type or has a
           previously failed output path, then fail the build right
           away. */
        bool badStep = false;
        for (auto & r : newSteps) {
            BuildStatus buildStatus = bsSuccess;
            BuildStepStatus buildStepStatus = bssFailed;

            if (checkCachedFailure(r, conn)) {
                printMsg(lvlError, format("marking build %1% as cached failure") % build->id);
                buildStatus = step == r ? bsFailed : bsFailed;
                buildStepStatus = bssFailed;
            }

            if (buildStatus == bsSuccess) {
                bool supported = false;
                {
                    auto machines_(machines.lock()); // FIXME: use shared_mutex
                    for (auto & m : *machines_)
                        if (m->supportsStep(r)) { supported = true; break; }
                }

                if (!supported) {
                    printMsg(lvlError, format("aborting unsupported build %1%") % build->id);
                    buildStatus = bsUnsupported;
                    buildStepStatus = bssUnsupported;
                }
            }

            if (buildStatus != bsSuccess) {
                time_t now = time(0);
                pqxx::work txn(conn);
                txn.parameterized
                    ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $3, isCachedBuild = $4 where id = $1")
                    (build->id)
                    ((int) buildStatus)
                    (now)
                    (buildStatus != bsUnsupported ? 1 : 0).exec();
                createBuildStep(txn, 0, build, r, "", buildStepStatus);
                txn.commit();
                badStep = true;
                break;
            }
        }

        if (badStep) return;

        /* Note: if we exit this scope prior to this, the build and
           all newly created steps are destroyed. */

        {
            auto builds_(builds.lock());
            auto step_(step->state.lock());
            (*builds_)[build->id] = build;
            step_->builds.push_back(build);
            build->toplevel = step;
        }

        printMsg(lvlChatty, format("added build %1% (top-level step %2%, %3% new steps)")
            % build->id % step->drvPath % newSteps.size());

        /* Prior to this, the build is not visible to
           getDependentBuilds().  Now it is, so the build can be
           failed if a dependency fails. (It can't succeed right away
           because its top-level is not runnable yet). */

    };

    /* Now instantiate build steps for each new build. The builder
       threads can start building the runnable build steps right away,
       even while we're still processing other new builds. */
    while (!newBuilds.empty()) {
        auto build = newBuilds.begin()->second;
        newBuilds.erase(newBuilds.begin());

        newRunnable.clear();
        nrAdded = 0;
        createBuild(build);

        /* Add the new runnable build steps to ‘runnable’ and wake up
           the builder threads. */
        printMsg(lvlChatty, format("got %1% new runnable steps from %2% new builds") % newRunnable.size() % nrAdded);
        for (auto & r : newRunnable)
            makeRunnable(r);
    }
}


void State::removeCancelledBuilds(Connection & conn)
{
    /* Get the current set of queued builds. */
    std::set<BuildID> currentIds;
    {
        pqxx::work txn(conn);
        auto res = txn.exec("select id from Builds where finished = 0");
        for (auto const & row : res)
            currentIds.insert(row["id"].as<BuildID>());
    }

    auto builds_(builds.lock());

    for (auto i = builds_->begin(); i != builds_->end(); ) {
        if (currentIds.find(i->first) == currentIds.end()) {
            printMsg(lvlInfo, format("discarding cancelled build %1%") % i->first);
            i = builds_->erase(i);
            // FIXME: ideally we would interrupt active build steps here.
        } else
            ++i;
    }
}


Step::ptr State::createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath,
    std::set<Step::ptr> & newSteps, std::set<Step::ptr> & newRunnable)
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

    printMsg(lvlDebug, format("considering derivation ‘%1%’") % drvPath);

    auto step = std::make_shared<Step>();
    step->drvPath = drvPath;
    step->drv = readDerivation(drvPath);
    {
        auto i = step->drv.env.find("requiredSystemFeatures");
        if (i != step->drv.env.end())
            step->requiredSystemFeatures = tokenizeString<std::set<std::string>>(i->second);
    }
    newSteps.insert(step);

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
    printMsg(lvlDebug, format("creating build step ‘%1%’") % drvPath);

    /* Create steps for the dependencies. */
    bool hasDeps = false;
    for (auto & i : step->drv.inputDrvs) {
        Step::ptr dep = createStep(store, i.first, newSteps, newRunnable);
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

    printMsg(lvlDebug, format("destroying build step ‘%1%’") % step->drvPath);

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
    printMsg(lvlChatty, format("step ‘%1%’ is now runnable") % step->drvPath);

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
    while (true) {
        printMsg(lvlDebug, "dispatcher woken up");

        auto sleepUntil = system_time::max();

        {
            auto runnable_(runnable.lock());
            printMsg(lvlDebug, format("%1% runnable builds") % runnable_->size());

            /* FIXME: we're holding the runnable lock too long
               here. This could be more efficient. */

            system_time now = std::chrono::system_clock::now();

            for (auto i = runnable_->begin(); i != runnable_->end(); ) {
                auto step = i->lock();

                /* Delete dead steps. */
                if (!step) {
                    i = runnable_->erase(i);
                    continue;
                }

                /* Skip previously failed steps that aren't ready to
                   be retried. */
                {
                    auto step_(step->state.lock());
                    if (step_->tries > 0 && step_->after > now) {
                        if (step_->after < sleepUntil)
                            sleepUntil = step_->after;
                        ++i;
                        continue;
                    }
                }

                auto reservation = findMachine(step);
                if (!reservation) {
                    printMsg(lvlDebug, format("cannot execute step ‘%1%’ right now") % step->drvPath);
                    ++i;
                    continue;
                }

                i = runnable_->erase(i);

                auto builderThread = std::thread(&State::builder, this, step, reservation);
                builderThread.detach(); // FIXME?
            }
        }

        /* Sleep until we're woken up (either because a runnable build
           is added, or because a build finishes). */
        {
            std::unique_lock<std::mutex> lock(dispatcherMutex);
            printMsg(lvlDebug, format("dispatcher sleeping for %1%s") %
                std::chrono::duration_cast<std::chrono::seconds>(sleepUntil - std::chrono::system_clock::now()).count());
            dispatcherWakeup.wait_until(lock, sleepUntil);
            nrDispatcherWakeups++;
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
        if (!machine->supportsStep(step)) continue;
        {
            auto currentJobs_(machine->currentJobs.lock());
            if (*currentJobs_ >= machine->maxJobs) continue;
        }
        return std::make_shared<MachineReservation>(machine);
    }

    return 0;
}


void State::builder(Step::ptr step, MachineReservation::ptr reservation)
{
    bool retry = true;

    try {
        auto store = openStore(); // FIXME: pool
        retry = doBuildStep(store, step, reservation->machine);
    } catch (std::exception & e) {
        printMsg(lvlError, format("uncaught exception building ‘%1%’ on ‘%2%’: %3%")
            % step->drvPath % reservation->machine->sshName % e.what());
    }

    /* Release the machine and wake up the dispatcher. */
    assert(reservation.unique());
    reservation = 0;
    wakeDispatcher();

    /* If there was a temporary failure, retry the step after an
       exponentially increasing interval. */
    if (retry) {
        {
            auto step_(step->state.lock());
            step_->tries++;
            nrRetries++;
            if (step_->tries > maxNrRetries) maxNrRetries = step_->tries; // yeah yeah, not atomic
            int delta = retryInterval * powf(retryBackoff, step_->tries - 1);
            printMsg(lvlInfo, format("will retry ‘%1%’ after %2%s") % step->drvPath % delta);
            step_->after = std::chrono::system_clock::now() + std::chrono::seconds(delta);
        }

        makeRunnable(step);
    }
}


bool State::doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step,
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
               are gone (e.g. cancelled). So don't bother. This is
               very unlikely to happen, because normally Steps are
               only kept alive by being reachable from a
               Build. However, it's possible that a new Build just
               created a reference to this step. So to handle that
               possibility, we retry this step (putting it back in
               the runnable queue). If there are really no strong
               pointers to the step, it will be deleted. */
            printMsg(lvlInfo, format("cancelling build step ‘%1%’") % step->drvPath);
            return true;
        }

        for (auto build2 : dependents)
            if (build2->drvPath == step->drvPath) { build = build2; break; }

        if (!build) build = *dependents.begin();

        printMsg(lvlInfo, format("performing step ‘%1%’ on ‘%2%’ (needed by build %3% and %4% others)")
            % step->drvPath % machine->sshName % build->id % (dependents.size() - 1));
    }

    auto conn(dbPool.get());

    RemoteResult result;
    BuildResult res;
    int stepNr = 0;

    result.startTime = time(0);

    /* If any of the outputs have previously failed, then don't bother
       building again. */
    bool cachedFailure = checkCachedFailure(step, *conn);

    if (cachedFailure)
        result.status = RemoteResult::rrPermanentFailure;
    else {

        /* Create a build step record indicating that we started
           building. Also, mark the selected build as busy. */
        {
            pqxx::work txn(*conn);
            stepNr = createBuildStep(txn, result.startTime, build, step, machine->sshName, bssBusy);
            txn.parameterized("update Builds set busy = 1 where id = $1")(build->id).exec();
            txn.commit();
        }

        try {
            /* FIXME: referring builds may have conflicting timeouts. */
            buildRemote(store, machine->sshName, machine->sshKey, step->drvPath, step->drv,
                logDir, build->maxSilentTime, build->buildTimeout, result);
        } catch (Error & e) {
            result.status = RemoteResult::rrMiscFailure;
            result.errorMsg = e.msg();
            printMsg(lvlError, format("irregular failure building ‘%1%’ on ‘%2%’: %3%")
                % step->drvPath % machine->sshName % e.msg());
        }

        if (result.status == RemoteResult::rrSuccess) res = getBuildResult(store, step->drv);
    }

    if (!result.stopTime) result.stopTime = time(0);

    bool retry = false;
    if (result.status == RemoteResult::rrMiscFailure) {
        auto step_(step->state.lock());
        retry = step_->tries + 1 < maxTries;
    }

    /* Remove this step. After this, incoming builds that depend on
       drvPath will either see that the output paths exist, or will
       create a new build step for drvPath. The latter is fine - it
       won't conflict with this one, because we're removing it. In any
       case, the set of dependent builds for ‘step’ can't increase
       anymore because ‘step’ is no longer visible to createStep(). */
    if (!retry) {
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

            finishBuildStep(txn, result.startTime, result.stopTime, build->id, stepNr, machine->sshName, bssSuccess);

            /* Mark all builds of which this derivation is the top
               level as succeeded. */
            for (auto build2 : direct)
                markSucceededBuild(txn, build2, res, false, result.startTime, result.stopTime);

        } else {
            /* Failure case. */

            BuildStatus buildStatus =
                result.status == RemoteResult::rrPermanentFailure ? bsFailed :
                result.status == RemoteResult::rrTimedOut ? bsTimedOut :
                bsAborted;
            BuildStepStatus buildStepStatus =
                result.status == RemoteResult::rrPermanentFailure ? bssFailed :
                result.status == RemoteResult::rrTimedOut ? bssTimedOut :
                bssAborted;

            /* For regular failures, we don't care about the error
               message. */
            if (buildStatus != bsAborted) result.errorMsg = "";

            if (!cachedFailure && !retry) {

                /* Create failed build steps for every build that depends
                   on this. */
                for (auto build2 : dependents) {
                    if (build == build2) continue;
                    createBuildStep(txn, 0, build2, step, machine->sshName,
                        buildStepStatus, result.errorMsg, build->id);
                }

            }

            if (!cachedFailure)
                finishBuildStep(txn, result.startTime, result.stopTime, build->id,
                    stepNr, machine->sshName, buildStepStatus, result.errorMsg);

            /* Mark all builds that depend on this derivation as failed. */
            if (!retry)
                for (auto build2 : dependents) {
                    printMsg(lvlError, format("marking build %1% as failed") % build2->id);
                    txn.parameterized
                        ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $4, isCachedBuild = $5 where id = $1")
                        (build2->id)
                        ((int) (build2->drvPath != step->drvPath && buildStatus == bsFailed ? bsDepFailed : buildStatus))
                        (result.startTime)
                        (result.stopTime)
                        (cachedFailure ? 1 : 0).exec();
                    build2->finishedInDB = true; // FIXME: txn might fail
                }

            /* Remember failed paths in the database so that they
               won't be built again. */
            if (!cachedFailure && result.status == RemoteResult::rrPermanentFailure)
                for (auto & path : outputPaths(step->drv))
                    txn.parameterized("insert into FailedPaths values ($1)")(path).exec();
        }

        txn.commit();
    }

    /* In case of success, destroy all Build objects of which ‘step’
       is the top-level derivation. In case of failure, destroy all
       dependent Build objects. Any Steps not referenced by other
       Builds will be destroyed as well. */
    if (!retry)
        for (auto build2 : dependents)
            if (build2->toplevel == step || result.status != RemoteResult::rrSuccess) {
                auto builds_(builds.lock());
                builds_->erase(build2->id);
            }

    /* Remove the step from the graph. In case of success, make
       dependent build steps runnable if they have no other
       dependencies. */
    if (!retry)
        destroyStep(step, result.status == RemoteResult::rrSuccess);

    return retry;
}


void State::markSucceededBuild(pqxx::work & txn, Build::ptr build,
    const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime)
{
    printMsg(lvlInfo, format("marking build %1% as succeeded") % build->id);

    txn.parameterized
        ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $4, size = $5, closureSize = $6, releaseName = $7, isCachedBuild = $8 where id = $1")
        (build->id)
        ((int) (res.failed ? bsFailedWithOutput : bsSuccess))
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


bool State::checkCachedFailure(Step::ptr step, Connection & conn)
{
    pqxx::work txn(conn);
    for (auto & path : outputPaths(step->drv))
        if (!txn.parameterized("select 1 from FailedPaths where path = $1")(path).exec().empty())
            return true;
    return false;
}


void State::dumpStatus()
{
    {
        auto builds_(builds.lock());
        printMsg(lvlError, format("%1% queued builds") % builds_->size());
    }
    {
        auto steps_(steps.lock());
        for (auto i = steps_->begin(); i != steps_->end(); )
            if (i->second.lock()) ++i; else i = steps_->erase(i);
        printMsg(lvlError, format("%1% pending/active build steps") % steps_->size());
    }
    {
        auto runnable_(runnable.lock());
        for (auto i = runnable_->begin(); i != runnable_->end(); )
            if (i->lock()) ++i; else i = runnable_->erase(i);
        printMsg(lvlError, format("%1% runnable build steps") % runnable_->size());
    }
    printMsg(lvlError, format("%1% build step retries") % nrRetries);
    printMsg(lvlError, format("%1% most retries for any build step") % maxNrRetries);
    printMsg(lvlError, format("%1% queue wakeups") % nrQueueWakeups);
    printMsg(lvlError, format("%1% dispatcher wakeups") % nrDispatcherWakeups);
    printMsg(lvlError, format("%1% database connections") % dbPool.count());
    {
        auto machines_(machines.lock());
        for (auto & m : *machines_) {
            auto currentJobs_(m->currentJobs.lock());
            printMsg(lvlError, format("machine %1%: %2%/%3% active")
                % m->sshName % *currentJobs_ % m->maxJobs);
        }
    }
}


void State::run()
{
    clearBusy(0);

    loadMachines();

    auto queueMonitorThread = std::thread(&State::queueMonitor, this);

    std::thread(&State::dispatcher, this).detach();

    queueMonitorThread.join();
}


int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();

        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);

        bool unlock = false;

        parseCmdLine(argc, argv, [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--unlock")
                unlock = true;
            else
                return false;
            return true;
        });

        settings.buildVerbosity = lvlVomit;
        settings.useSubstitutes = false;
        settings.lockCPU = false;

        /* FIXME: need some locking to prevent multiple instances of
           hydra-queue-runner. */
        State state;
        if (unlock)
            state.clearBusy(0);
        else
            state.run();
    });
}

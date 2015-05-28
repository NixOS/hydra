#include <atomic>
#include <condition_variable>
#include <iostream>
#include <map>
#include <memory>
#include <thread>

#include <pqxx/pqxx>

#include "build-result.hh"
#include "store-api.hh"
#include "derivations.hh"
#include "shared.hh"
#include "globals.hh"

using namespace nix;


std::mutex exitRequestMutex;
std::condition_variable exitRequest;
bool exitRequested(false);

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


struct Build
{
    typedef std::shared_ptr<Build> ptr;
    typedef std::weak_ptr<Build> wptr;

    BuildID id;
    Path drvPath;
    std::map<string, Path> outputs;

    bool finishedInDB;

    Build() : finishedInDB(false) { }
};


struct Step
{
    typedef std::shared_ptr<Step> ptr;
    typedef std::weak_ptr<Step> wptr;
    Path drvPath;
    Derivation drv;

    /* The build steps on which this step depends. */
    std::set<Step::ptr> deps;

    /* The build steps that depend on this step. */
    std::vector<Step::wptr> rdeps;

    /* Builds that have this step as the top-level derivation. */
    std::vector<Build::wptr> builds;
};


class State
{
private:

    std::thread queueMonitorThread;

    /* The queued builds. */
    std::map<BuildID, Build::ptr> builds;

    /* All active or pending build steps (i.e. dependencies of the
       queued builds). */
    std::map<Path, Step::ptr> steps;

    /* Build steps that have no unbuilt dependencies. */
    std::set<Step::ptr> runnable;

    std::mutex runnableMutex;
    std::condition_variable runnableCV;

public:
    State();

    ~State();

    void markActiveBuildStepsAsAborted(pqxx::connection & conn, time_t stopTime);

    int createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
        BuildStepStatus status, const std::string & errorMsg = "", BuildID propagatedFrom = 0);

    void finishBuildStep(pqxx::work & txn, time_t stopTime, BuildID buildId, int stepNr,
        BuildStepStatus status, const string & errorMsg = "", BuildID propagatedFrom = 0);

    void updateBuild(pqxx::work & txn, Build::ptr build, BuildStatus status);

    void queueMonitorThreadEntry();

    void getQueuedBuilds(std::shared_ptr<StoreAPI> store, pqxx::connection & conn);

    Step::ptr createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath);

    void destroyStep(Step::ptr step, bool proceed);

    /* Get the builds that depend on the given step. */
    std::set<Build::ptr> getDependentBuilds(Step::ptr step);

    void makeRunnable(Step::ptr step);

    void builderThreadEntry(int slot);

    void doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step);

    void markSucceededBuild(pqxx::work & txn, Build::ptr build,
        const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime);

    void run();
};


State::State()
{
}


State::~State()
{
    try {
        Connection conn;
        printMsg(lvlError, "clearing active build steps...");
        markActiveBuildStepsAsAborted(conn, time(0));
    } catch (...) {
        ignoreException();
    }
}


void State::markActiveBuildStepsAsAborted(pqxx::connection & conn, time_t stopTime)
{
    pqxx::work txn(conn);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, stopTime = $2 where busy = 1")
        ((int) bssAborted)
        (stopTime, stopTime != 0).exec();
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


void State::finishBuildStep(pqxx::work & txn, time_t stopTime, BuildID buildId, int stepNr,
    BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, propagatedFrom = $4, errorMsg = $5, stopTime = $6 where build = $2 and stepnr = $3")
        ((int) status)(buildId)(stepNr)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (stopTime, stopTime != 0).exec();
}


void State::queueMonitorThreadEntry()
{
    auto store = openStore(); // FIXME: pool

    Connection conn;

    while (true) {
        getQueuedBuilds(store, conn);

        {
            std::unique_lock<std::mutex> lock(exitRequestMutex);
            exitRequest.wait_for(lock, std::chrono::seconds(5));
            if (exitRequested) break;
        }
    }

    printMsg(lvlError, "queue monitor exits");
}


void State::getQueuedBuilds(std::shared_ptr<StoreAPI> store, pqxx::connection & conn)
{
    printMsg(lvlError, "checking the queue...");

    pqxx::work txn(conn);

    // FIXME: query only builds with ID higher than the previous
    // highest.
    auto res = txn.exec("select * from Builds where finished = 0");

    // FIXME: don't process inside a txn.
    for (auto const & row : res) {
        BuildID id = row["id"].as<BuildID>();
        if (builds.find(id) != builds.end()) continue;

        Build::ptr build(new Build);
        build->id = id;
        build->drvPath = row["drvPath"].as<string>();

        printMsg(lvlInfo, format("loading build %1% (%2%:%3%:%4%)") % id % row["project"] % row["jobset"] % row["job"]);

        if (!store->isValidPath(build->drvPath)) {
            /* Derivation has been GC'ed prematurely. */
            Connection conn;
            pqxx::work txn(conn);
            txn.parameterized
                ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $3, errorMsg = $4 where id = $1")
                (build->id)
                ((int) bsAborted)
                (time(0))
                ("derivation was garbage-collected prior to build").exec();
            txn.commit();
            continue;
        }

        Step::ptr step = createStep(store, build->drvPath);
        if (!step) {
            Derivation drv = readDerivation(build->drvPath);
            BuildResult res = getBuildResult(store, drv);

            Connection conn;
            pqxx::work txn(conn);
            time_t now = time(0);
            markSucceededBuild(txn, build, res, true, now, now);
            txn.commit();

            continue;
        }

        step->builds.push_back(build);

        builds[id] = build;
    }
}


Step::ptr State::createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath)
{
    auto prev = steps.find(drvPath);
    if (prev != steps.end()) return prev->second;

    printMsg(lvlInfo, format("considering derivation ‘%1%’") % drvPath);

    Step::ptr step(new Step);
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
    for (auto & i : step->drv.inputDrvs) {
        Step::ptr dep = createStep(store, i.first);
        if (dep) {
            step->deps.insert(dep);
            dep->rdeps.push_back(step);
        }
    }

    steps[drvPath] = step;

    if (step->deps.empty()) makeRunnable(step);

    return step;
}


void State::destroyStep(Step::ptr step, bool proceed)
{
    steps.erase(step->drvPath);

    for (auto & rdep_ : step->rdeps) {
        auto rdep = rdep_.lock();
        if (!rdep) continue;
        assert(rdep->deps.find(step) != rdep->deps.end());
        rdep->deps.erase(step);
        if (proceed) {
            /* If this rdep has no other dependencies, then we can now
               build it. */
            if (rdep->deps.empty())
                makeRunnable(rdep);
        } else
            /* If ‘step’ failed, then delete all dependent steps as
               well. */
            destroyStep(rdep, false);
    }

    for (auto & build_ : step->builds) {
        auto build = build_.lock();
        if (!build) continue;
        assert(build->drvPath == step->drvPath);
        assert(build->finishedInDB);
    }
}


std::set<Build::ptr> State::getDependentBuilds(Step::ptr step)
{
    std::set<Step::ptr> done;
    std::set<Build::ptr> res;

    std::function<void(Step::ptr)> visit;

    visit = [&](Step::ptr step) {
        if (done.find(step) != done.end()) return;
        done.insert(step);

        for (auto & build : step->builds) {
            auto build2 = build.lock();
            if (build2) res.insert(build2);
        }

        for (auto & rdep : step->rdeps) {
            auto rdep2 = rdep.lock();
            if (rdep2) visit(rdep2);
        }
    };

    visit(step);

    return res;
}


void State::makeRunnable(Step::ptr step)
{
    assert(step->deps.empty());

    {
        std::lock_guard<std::mutex> lock(runnableMutex);
        runnable.insert(step);
    }

    runnableCV.notify_one();
}


void State::builderThreadEntry(int slot)
{
    auto store = openStore(); // FIXME: pool

    while (true)  {
        Step::ptr step;
        {
            std::unique_lock<std::mutex> lock(runnableMutex);
            while (runnable.empty())
                runnableCV.wait(lock);
            step = *runnable.begin();
            runnable.erase(step);
        }

        printMsg(lvlError, format("slot %1%: got build step ‘%2%’") % slot % step->drvPath);

        doBuildStep(store, step);
    }

    printMsg(lvlError, "builder thread exits");
}


void State::doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step)
{
    assert(step->deps.empty());

    /* There can be any number of builds in the database that depend
       on this derivation. Arbitrarily pick one (though preferring
       those build of which this is the top-level derivation) for the
       purpose of creating build steps. We could create a build step
       record for every build, but that could be very expensive
       (e.g. a stdenv derivation can be a dependency of tens of
       thousands of builds), so we don't. */
    Build::ptr build;

    auto builds = getDependentBuilds(step);

    if (builds.empty()) {
        /* Apparently all builds that depend on this derivation are
           gone (e.g. cancelled). So don't bother. */
        printMsg(lvlInfo, format("cancelling build step ‘%1%’") % step->drvPath);
        destroyStep(step, true);
        return;
    }

    for (auto build2 : builds)
        if (build2->drvPath == step->drvPath) { build = build2; break; }

    if (!build) build = *builds.begin();

    printMsg(lvlInfo, format("performing build step ‘%1%’ (needed by %2% builds)") % step->drvPath % builds.size());

    /* Create a build step record indicating that we started
       building. */
    Connection conn;
    time_t startTime = time(0);
    int stepNr;
    {
        pqxx::work txn(conn);
        stepNr = createBuildStep(txn, startTime, build, step, bssBusy);
        txn.commit();
    }

    bool success = false;
    std::string errorMsg;
    try {
        store->buildPaths(PathSet({step->drvPath}));
        success = true;
    } catch (Error & e) {
        errorMsg = e.msg();
    }

    time_t stopTime = time(0);

    BuildResult res;
    if (success) res = getBuildResult(store, step->drv);

    // FIXME: handle failed-with-output

    // FIXME: handle new builds having been added in the meantime.

    {
        pqxx::work txn(conn);

        if (success) {

            finishBuildStep(txn, stopTime, build->id, stepNr, bssSuccess);

            /* Mark all builds of which this derivation is the top
               level as succeeded. */
            for (auto build2_ : step->builds) {
                auto build2 = build2_.lock();
                if (!build2) continue;
                markSucceededBuild(txn, build2, res, false, startTime, stopTime);
            }

        } else {
            /* Create failed build steps for every build that depends
               on this. */
            finishBuildStep(txn, stopTime, build->id, stepNr, bssFailed, errorMsg);

            for (auto build2 : builds) {
                if (build == build2) continue;
                createBuildStep(txn, stopTime, build2, step, bssFailed, errorMsg, build->id);
            }

            /* Mark all builds that depend on this derivation as failed. */
            for (auto build2 : builds) {
                txn.parameterized
                    ("update Builds set finished = 1, isCachedBuild = 0, buildStatus = $2, startTime = $3, stopTime = $4 where id = $1")
                    (build2->id)
                    ((int) (build2->drvPath == step->drvPath ? bsFailed : bsDepFailed))
                    (startTime)
                    (stopTime).exec();
                build2->finishedInDB = true; // FIXME: txn might fail
            }
        }

        txn.commit();

    }

    /* Remove the build step from the graph. */
    destroyStep(step, success);
}


void State::markSucceededBuild(pqxx::work & txn, Build::ptr build,
    const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime)
{
    txn.parameterized
        ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $4, size = $5, closureSize = $6, releaseName = $7, isCachedBuild = $8 where id = $1")
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
    {
        Connection conn;
        markActiveBuildStepsAsAborted(conn, 0);
    }

    queueMonitorThread = std::thread(&State::queueMonitorThreadEntry, this);

    sleep(1);

    for (int n = 0; n < 4; n++)
        std::thread(&State::builderThreadEntry, this, n).detach();

    queueMonitorThread.join();
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

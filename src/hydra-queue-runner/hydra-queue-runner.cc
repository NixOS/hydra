#include <iostream>
#include <memory>
#include <map>
#include <pqxx/pqxx>

#include "build-result.hh"
#include "store-api.hh"
#include "derivations.hh"
#include "shared.hh"
#include "globals.hh"

using namespace nix;


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
    /* The queued builds. */
    std::map<BuildID, Build::ptr> builds;

    /* All active or pending build steps (i.e. dependencies of the
       queued builds). */
    std::map<Path, Step::ptr> steps;

    /* Build steps that have no unbuilt dependencies. */
    std::set<Step::ptr> runnable;

public:
    State();

    ~State();

    void markActiveBuildStepsAsAborted(pqxx::connection & conn, time_t stopTime);

    int createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
        BuildStepStatus status, const std::string & errorMsg = "", BuildID propagatedFrom = 0);

    void finishBuildStep(pqxx::work & txn, time_t stopTime, BuildID buildId, int stepNr,
        BuildStepStatus status, const string & errorMsg = "", BuildID propagatedFrom = 0);

    void updateBuild(pqxx::work & txn, Build::ptr build, BuildStatus status);

    void getQueuedBuilds(pqxx::connection & conn);

    Step::ptr createStep(const Path & drvPath);

    void destroyStep(Step::ptr step, bool proceed);

    /* Get the builds that depend on the given step. */
    std::set<Build::ptr> getDependentBuilds(Step::ptr step);

    void doBuildSteps();

    void doBuildStep(Step::ptr step);

    void markSucceededBuild(pqxx::work & txn, Build::ptr build,
        const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime);
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
    auto stm = txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, stopTime = $2 where busy = 1")
        ((int) bssAborted);
    if (stopTime) stm(stopTime); else stm();
    stm.exec();
    txn.commit();
}


int State::createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
    BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    auto res = txn.parameterized("select max(stepnr) from BuildSteps where build = $1")(build->id).exec();
    int stepNr = res[0][0].is_null() ? 1 : res[0][0].as<int>() + 1;

    auto stm = txn.parameterized
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, startTime, system, status, propagatedFrom, errorMsg, stopTime) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)")
        (build->id)(stepNr)(0)(step->drvPath)(status == bssBusy ? 1 : 0)(startTime)(step->drv.platform);
    if (status == bssBusy) stm(); else stm((int) status);
    if (propagatedFrom) stm(propagatedFrom); else stm();
    if (errorMsg != "") stm(errorMsg); else stm();
    if (status == bssBusy) stm(); else stm(startTime);
    stm.exec();

    for (auto & output : step->drv.outputs)
        txn.parameterized
            ("insert into BuildStepOutputs (build, stepnr, name, path) values ($1, $2, $3, $4)")
            (build->id)(stepNr)(output.first)(output.second.path).exec();

    return stepNr;
}


void State::finishBuildStep(pqxx::work & txn, time_t stopTime, BuildID buildId, int stepNr,
    BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    auto stm = txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, propagatedFrom = $4, errorMsg = $5, stopTime = $6 where build = $2 and stepnr = $3")
        ((int) status)(buildId)(stepNr);
    if (propagatedFrom) stm(propagatedFrom); else stm();
    if (errorMsg != "") stm(errorMsg); else stm();
    if (stopTime) stm(stopTime); else stm();
    stm.exec();
}


void State::getQueuedBuilds(pqxx::connection & conn)
{
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

        Step::ptr step = createStep(build->drvPath);
        if (!step) {
            Derivation drv = readDerivation(build->drvPath);
            BuildResult res = getBuildResult(drv);

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


Step::ptr State::createStep(const Path & drvPath)
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
        Step::ptr dep = createStep(i.first);
        if (dep) {
            step->deps.insert(dep);
            dep->rdeps.push_back(step);
        }
    }

    steps[drvPath] = step;

    if (step->deps.empty()) runnable.insert(step);

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
                runnable.insert(rdep);
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


void State::doBuildSteps()
{
    while (!runnable.empty()) {
        printMsg(lvlInfo, format("%1% runnable steps") % runnable.size());
        Step::ptr step = *runnable.begin();
        runnable.erase(step);
        doBuildStep(step);
    }
}


void State::doBuildStep(Step::ptr step)
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
    if (success) res = getBuildResult(step->drv);

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
    auto stm = txn.parameterized
        ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $4, size = $5, closureSize = $6, releaseName = $7, isCachedBuild = $8 where id = $1")
        (build->id)
        ((int) bsSuccess)
        (startTime)
        (stopTime)
        (res.size)
        (res.closureSize);
    if (res.releaseName != "") stm(res.releaseName); else stm();
    stm(isCachedBuild ? 1 : 0);
    stm.exec();

    unsigned int productNr = 1;
    for (auto & product : res.products) {
        auto stm = txn.parameterized
            ("insert into BuildProducts (build, productnr, type, subtype, fileSize, sha1hash, sha256hash, path, name, defaultPath) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)")
            (build->id)
            (productNr++)
            (product.type)
            (product.subtype);
        if (product.isRegular) stm(product.fileSize); else stm();
        if (product.isRegular) stm(printHash(product.sha1hash)); else stm();
        if (product.isRegular) stm(printHash(product.sha256hash)); else stm();
        stm
            (product.path)
            (product.name)
            (product.defaultPath).exec();
    }

    build->finishedInDB = true; // FIXME: txn might fail
}


int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();

        settings.buildVerbosity = lvlVomit;
        settings.useSubstitutes = false;

        store = openStore();

        /* FIXME: need some locking to prevent multiple instances of
           hydra-queue-runner. */

        Connection conn;

        State state;

        state.markActiveBuildStepsAsAborted(conn, 0);

        state.getQueuedBuilds(conn);

        state.doBuildSteps();
    });
}

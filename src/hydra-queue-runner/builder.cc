#include <cmath>

#include "state.hh"
#include "hydra-build-result.hh"
#include "finally.hh"
#include "binary-cache-store.hh"

using namespace nix;


void setThreadName(const std::string & name)
{
#ifdef __linux__
   pthread_setname_np(pthread_self(), std::string(name, 0, 15).c_str());
#endif
}


void State::builder(MachineReservation::ptr reservation)
{
    setThreadName("bld~" + std::string(reservation->step->drvPath.to_string()));

    StepResult res = sRetry;

    nrStepsStarted++;

    Step::wptr wstep = reservation->step;

    {
        auto activeStep = std::make_shared<ActiveStep>();
        activeStep->step = reservation->step;
        activeSteps_.lock()->insert(activeStep);

        Finally removeActiveStep([&]() {
            activeSteps_.lock()->erase(activeStep);
        });

        try {
            auto destStore = getDestStore();
            res = doBuildStep(destStore, reservation, activeStep);
        } catch (std::exception & e) {
            printMsg(lvlError, "uncaught exception building ‘%s’ on ‘%s’: %s",
                localStore->printStorePath(reservation->step->drvPath),
                reservation->machine->sshName,
                e.what());
        }
    }

    /* Release the machine and wake up the dispatcher. */
    assert(reservation.unique());
    reservation = 0;
    wakeDispatcher();

    /* If there was a temporary failure, retry the step after an
       exponentially increasing interval. */
    Step::ptr step = wstep.lock();
    if (res != sDone && step) {

        if (res == sRetry) {
            auto step_(step->state.lock());
            step_->tries++;
            nrRetries++;
            if (step_->tries > maxNrRetries) maxNrRetries = step_->tries; // yeah yeah, not atomic
            int delta = retryInterval * std::pow(retryBackoff, step_->tries - 1) + (rand() % 10);
            printMsg(lvlInfo, "will retry ‘%s’ after %ss", localStore->printStorePath(step->drvPath), delta);
            step_->after = std::chrono::system_clock::now() + std::chrono::seconds(delta);
        }

        makeRunnable(step);
    }
}


State::StepResult State::doBuildStep(nix::ref<Store> destStore,
    MachineReservation::ptr reservation,
    std::shared_ptr<ActiveStep> activeStep)
{
    auto & step(reservation->step);
    auto & machine(reservation->machine);

    {
        auto step_(step->state.lock());
        assert(step_->created);
        assert(!step->finished);
    }

    /* There can be any number of builds in the database that depend
       on this derivation. Arbitrarily pick one (though preferring a
       build of which this is the top-level derivation) for the
       purpose of creating build steps. We could create a build step
       record for every build, but that could be very expensive
       (e.g. a stdenv derivation can be a dependency of tens of
       thousands of builds), so we don't.

       We don't keep a Build::ptr here to allow
       State::processQueueChange() to detect whether a step can be
       cancelled (namely if there are no more Builds referring to
       it). */
    BuildID buildId;
    std::optional<StorePath> buildDrvPath;
    BuildOptions buildOptions;
    buildOptions.repeats = step->isDeterministic ? 1 : 0;
    buildOptions.maxLogSize = maxLogSize;
    buildOptions.enforceDeterminism = step->isDeterministic;

    auto conn(dbPool.get());

    {
        std::set<Build::ptr> dependents;
        std::set<Step::ptr> steps;
        getDependents(step, dependents, steps);

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
            printMsg(lvlInfo, "maybe cancelling build step ‘%s’", localStore->printStorePath(step->drvPath));
            return sMaybeCancelled;
        }

        Build::ptr build;

        for (auto build2 : dependents) {
            if (build2->drvPath == step->drvPath) {
                build = build2;
                pqxx::work txn(*conn);
                notifyBuildStarted(txn, build->id);
                txn.commit();
            }
            {
                auto i = jobsetRepeats.find(std::make_pair(build2->projectName, build2->jobsetName));
                if (i != jobsetRepeats.end())
                    buildOptions.repeats = std::max(buildOptions.repeats, i->second);
            }
        }
        if (!build) build = *dependents.begin();

        buildId = build->id;
        buildDrvPath = build->drvPath;
        buildOptions.maxSilentTime = build->maxSilentTime;
        buildOptions.buildTimeout = build->buildTimeout;

        printInfo("performing step ‘%s’ %d times on ‘%s’ (needed by build %d and %d others)",
            localStore->printStorePath(step->drvPath), buildOptions.repeats + 1, machine->sshName, buildId, (dependents.size() - 1));
    }

    if (!buildOneDone)
        buildOneDone = buildId == buildOne && step->drvPath == *buildDrvPath;

    RemoteResult result;
    BuildOutput res;
    unsigned int stepNr = 0;
    bool stepFinished = false;

    Finally clearStep([&]() {
        if (stepNr && !stepFinished) {
            printError("marking step %d of build %d as orphaned", stepNr, buildId);
            auto orphanedSteps_(orphanedSteps.lock());
            orphanedSteps_->emplace(buildId, stepNr);
        }

        if (stepNr) {
            /* Upload the log file to the binary cache. FIXME: should
               be done on a worker thread. */
            try {
                auto store = destStore.dynamic_pointer_cast<BinaryCacheStore>();
                if (uploadLogsToBinaryCache && store && pathExists(result.logFile)) {
                    store->upsertFile("log/" + std::string(step->drvPath.to_string()), readFile(result.logFile), "text/plain; charset=utf-8");
                    unlink(result.logFile.c_str());
                }
            } catch (...) {
                ignoreException();
            }
        }
    });

    time_t stepStartTime = result.startTime = time(0);

    /* If any of the outputs have previously failed, then don't bother
       building again. */
    if (checkCachedFailure(step, *conn))
        result.stepStatus = bsCachedFailure;
    else {

        /* Create a build step record indicating that we started
           building. */
        {
            auto mc = startDbUpdate();
            pqxx::work txn(*conn);
            stepNr = createBuildStep(txn, result.startTime, buildId, step, machine->sshName, bsBusy);
            txn.commit();
        }

        auto updateStep = [&](StepState stepState) {
            pqxx::work txn(*conn);
            updateBuildStep(txn, buildId, stepNr, stepState);
            txn.commit();
        };

        /* Do the build. */
        NarMemberDatas narMembers;

        try {
            /* FIXME: referring builds may have conflicting timeouts. */
            buildRemote(destStore, machine, step, buildOptions, result, activeStep, updateStep, narMembers);
        } catch (Error & e) {
            if (activeStep->state_.lock()->cancelled) {
                printInfo("marking step %d of build %d as cancelled", stepNr, buildId);
                result.stepStatus = bsCancelled;
                result.canRetry = false;
            } else {
                result.stepStatus = bsAborted;
                result.errorMsg = e.msg();
                result.canRetry = true;
            }
        }

        if (result.stepStatus == bsSuccess) {
            updateStep(ssPostProcessing);
            res = getBuildOutput(destStore, narMembers, *step->drv);
        }
    }

    time_t stepStopTime = time(0);
    if (!result.stopTime) result.stopTime = stepStopTime;

    /* For standard failures, we don't care about the error
       message. */
    if (result.stepStatus != bsAborted)
        result.errorMsg = "";

    /* Account the time we spent building this step by dividing it
       among the jobsets that depend on it. */
    {
        auto step_(step->state.lock());
        if (!step_->jobsets.empty()) {
            // FIXME: loss of precision.
            time_t charge = (result.stopTime - result.startTime) / step_->jobsets.size();
            for (auto & jobset : step_->jobsets)
                jobset->addStep(result.startTime, charge);
        }
    }

    /* Finish the step in the database. */
    if (stepNr) {
        pqxx::work txn(*conn);
        finishBuildStep(txn, result, buildId, stepNr, machine->sshName);
        txn.commit();
    }

    /* The step had a hopefully temporary failure (e.g. network
       issue). Retry a number of times. */
    if (result.canRetry) {
        printMsg(lvlError, "possibly transient failure building ‘%s’ on ‘%s’: %s",
            localStore->printStorePath(step->drvPath), machine->sshName, result.errorMsg);
        assert(stepNr);
        bool retry;
        {
            auto step_(step->state.lock());
            retry = step_->tries + 1 < maxTries;
        }
        if (retry) {
            auto mc = startDbUpdate();
            stepFinished = true;
            if (buildOneDone) exit(1);
            return sRetry;
        }
    }

    if (result.stepStatus == bsSuccess) {

        assert(stepNr);

        for (auto & i : step->drv->outputsAndOptPaths(*localStore)) {
            if (i.second.second)
               addRoot(*i.second.second);
        }

        /* Register success in the database for all Build objects that
           have this step as the top-level step. Since the queue
           monitor thread may be creating new referring Builds
           concurrently, and updating the database may fail, we do
           this in a loop, marking all known builds, repeating until
           there are no unmarked builds.
        */

        std::vector<BuildID> buildIDs;

        while (true) {

            /* Get the builds that have this one as the top-level. */
            std::vector<Build::ptr> direct;
            {
                auto steps_(steps.lock());
                auto step_(step->state.lock());

                for (auto & b_ : step_->builds) {
                    auto b = b_.lock();
                    if (b && !b->finishedInDB) direct.push_back(b);
                }

                /* If there are no builds left to update in the DB,
                   then we're done (except for calling
                   finishBuildStep()). Delete the step from
                   ‘steps’. Since we've been holding the ‘steps’ lock,
                   no new referrers can have been added in the
                   meantime or be added afterwards. */
                if (direct.empty()) {
                    printMsg(lvlDebug, "finishing build step ‘%s’",
                        localStore->printStorePath(step->drvPath));
                    steps_->erase(step->drvPath);
                }
            }

            /* Update the database. */
            {
                auto mc = startDbUpdate();

                pqxx::work txn(*conn);

                for (auto & b : direct) {
                    printInfo("marking build %1% as succeeded", b->id);
                    markSucceededBuild(txn, b, res, buildId != b->id || result.isCached,
                        result.startTime, result.stopTime);
                }

                txn.commit();
            }

            stepFinished = true;

            if (direct.empty()) break;

            /* Remove the direct dependencies from ‘builds’. This will
               cause them to be destroyed. */
            for (auto & b : direct) {
                auto builds_(builds.lock());
                b->finishedInDB = true;
                builds_->erase(b->id);
                buildIDs.push_back(b->id);
            }
        }

        /* Send notification about the builds that have this step as
           the top-level. */
        {
            pqxx::work txn(*conn);
            for (auto id : buildIDs)
                notifyBuildFinished(txn, id, {});
            txn.commit();
        }

        /* Wake up any dependent steps that have no other
           dependencies. */
        {
            auto step_(step->state.lock());
            for (auto & rdepWeak : step_->rdeps) {
                auto rdep = rdepWeak.lock();
                if (!rdep) continue;

                bool runnable = false;
                {
                    auto rdep_(rdep->state.lock());
                    rdep_->deps.erase(step);
                    /* Note: if the step has not finished
                       initialisation yet, it will be made runnable in
                       createStep(), if appropriate. */
                    if (rdep_->deps.empty() && rdep_->created) runnable = true;
                }

                if (runnable) makeRunnable(rdep);
            }
        }

    } else
        failStep(*conn, step, buildId, result, machine, stepFinished);

    // FIXME: keep stats about aborted steps?
    nrStepsDone++;
    totalStepTime += stepStopTime - stepStartTime;
    totalStepBuildTime += result.stopTime - result.startTime;
    machine->state->nrStepsDone++;
    machine->state->totalStepTime += stepStopTime - stepStartTime;
    machine->state->totalStepBuildTime += result.stopTime - result.startTime;

    if (buildOneDone) exit(0); // testing hack; FIXME: this won't run plugins

    return sDone;
}


void State::failStep(
    Connection & conn,
    Step::ptr step,
    BuildID buildId,
    const RemoteResult & result,
    Machine::ptr machine,
    bool & stepFinished)
{
    /* Register failure in the database for all Build objects that
       directly or indirectly depend on this step. */

    std::vector<BuildID> dependentIDs;

    while (true) {
        /* Get the builds and steps that depend on this step. */
        std::set<Build::ptr> indirect;
        {
            auto steps_(steps.lock());
            std::set<Step::ptr> steps;
            getDependents(step, indirect, steps);

            /* If there are no builds left, delete all referring
               steps from ‘steps’. As for the success case, we can
               be certain no new referrers can be added. */
            if (indirect.empty()) {
                for (auto & s : steps) {
                    printMsg(lvlDebug, "finishing build step ‘%s’",
                        localStore->printStorePath(s->drvPath));
                    steps_->erase(s->drvPath);
                }
            }
        }

        if (indirect.empty() && stepFinished) break;

        /* Update the database. */
        {
            auto mc = startDbUpdate();

            pqxx::work txn(conn);

            /* Create failed build steps for every build that
               depends on this, except when this step is cached
               and is the top-level of that build (since then it's
               redundant with the build's isCachedBuild field). */
            for (auto & build : indirect) {
                if ((result.stepStatus == bsCachedFailure && build->drvPath == step->drvPath) ||
                    ((result.stepStatus != bsCachedFailure && result.stepStatus != bsUnsupported) && buildId == build->id) ||
                    build->finishedInDB)
                    continue;
                createBuildStep(txn,
                    0, build->id, step, machine ? machine->sshName : "",
                    result.stepStatus, result.errorMsg, buildId == build->id ? 0 : buildId);
            }

            /* Mark all builds that depend on this derivation as failed. */
            for (auto & build : indirect) {
                if (build->finishedInDB) continue;
                printError("marking build %1% as failed", build->id);
                txn.exec_params0
                    ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $4, isCachedBuild = $5, notificationPendingSince = $4 where id = $1 and finished = 0",
                     build->id,
                     (int) (build->drvPath != step->drvPath && result.buildStatus() == bsFailed ? bsDepFailed : result.buildStatus()),
                     result.startTime,
                     result.stopTime,
                     result.stepStatus == bsCachedFailure ? 1 : 0);
                nrBuildsDone++;
            }

            /* Remember failed paths in the database so that they
               won't be built again. */
            if (result.stepStatus != bsCachedFailure && result.canCache)
                for (auto & i : step->drv->outputsAndOptPaths(*localStore))
                    if (i.second.second)
                       txn.exec_params0("insert into FailedPaths values ($1)", localStore->printStorePath(*i.second.second));

            txn.commit();
        }

        stepFinished = true;

        /* Remove the indirect dependencies from ‘builds’. This
           will cause them to be destroyed. */
        for (auto & b : indirect) {
            auto builds_(builds.lock());
            b->finishedInDB = true;
            builds_->erase(b->id);
            dependentIDs.push_back(b->id);
            if (!buildOneDone && buildOne == b->id) buildOneDone = true;
        }
    }

    /* Send notification about this build and its dependents. */
    {
        pqxx::work txn(conn);
        notifyBuildFinished(txn, buildId, dependentIDs);
        txn.commit();
    }
}


void State::addRoot(const StorePath & storePath)
{
    auto root = rootsDir + "/" + std::string(storePath.to_string());
    if (!pathExists(root)) writeFile(root, "");
}

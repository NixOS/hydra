#include <cmath>

#include "state.hh"
#include "build-result.hh"

using namespace nix;


void State::builder(MachineReservation::ptr reservation)
{
    StepResult res = sRetry;

    nrStepsStarted++;

    MaintainCount mc(nrActiveSteps);

    auto step = reservation->step;

    try {
        auto destStore = getDestStore();
        res = doBuildStep(destStore, step, reservation->machine);
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
    if (res != sDone) {
        if (res == sRetry) {
            auto step_(step->state.lock());
            step_->tries++;
            nrRetries++;
            if (step_->tries > maxNrRetries) maxNrRetries = step_->tries; // yeah yeah, not atomic
            int delta = retryInterval * powf(retryBackoff, step_->tries - 1) + (rand() % 10);
            printMsg(lvlInfo, format("will retry ‘%1%’ after %2%s") % step->drvPath % delta);
            step_->after = std::chrono::system_clock::now() + std::chrono::seconds(delta);
        }

        makeRunnable(step);
    }
}


State::StepResult State::doBuildStep(nix::ref<Store> destStore, Step::ptr step,
    Machine::ptr machine)
{
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
       thousands of builds), so we don't. */
    Build::ptr build;

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
            printMsg(lvlInfo, format("maybe cancelling build step ‘%1%’") % step->drvPath);
            return sMaybeCancelled;
        }

        for (auto build2 : dependents)
            if (build2->drvPath == step->drvPath) { build = build2; break; }

        if (!build) build = *dependents.begin();

        printMsg(lvlInfo, format("performing step ‘%1%’ on ‘%2%’ (needed by build %3% and %4% others)")
            % step->drvPath % machine->sshName % build->id % (dependents.size() - 1));
    }

    bool quit = build->id == buildOne && step->drvPath == build->drvPath;

    auto conn(dbPool.get());

    RemoteResult result;
    BuildOutput res;
    int stepNr = 0;

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
            stepNr = createBuildStep(txn, result.startTime, build, step, machine->sshName, bsBusy);
            txn.commit();
        }

        /* Do the build. */
        try {
            /* FIXME: referring builds may have conflicting timeouts. */
            buildRemote(destStore, machine, step, build->maxSilentTime, build->buildTimeout, result);
        } catch (NoTokens & e) {
            result.stepStatus = bsNarSizeLimitExceeded;
        } catch (Error & e) {
            result.stepStatus = bsAborted;
            result.errorMsg = e.msg();
            result.canRetry = true;
        }

        if (result.stepStatus == bsSuccess)
            res = getBuildOutput(destStore, ref<FSAccessor>(result.accessor), step->drv);
    }

    time_t stepStopTime = time(0);
    if (!result.stopTime) result.stopTime = stepStopTime;

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

    /* Asynchronously compress the log. */
    if (result.logFile != "") {
        {
            auto logCompressorQueue_(logCompressorQueue.lock());
            logCompressorQueue_->push(result.logFile);
        }
        logCompressorWakeup.notify_one();
    }

    /* The step had a hopefully temporary failure (e.g. network
       issue). Retry a number of times. */
    if (result.canRetry) {
        printMsg(lvlError, format("possibly transient failure building ‘%1%’ on ‘%2%’: %3%")
            % step->drvPath % machine->sshName % result.errorMsg);
        bool retry;
        {
            auto step_(step->state.lock());
            retry = step_->tries + 1 < maxTries;
        }
        if (retry) {
            auto mc = startDbUpdate();
            pqxx::work txn(*conn);
            finishBuildStep(txn, result.startTime, result.stopTime, result.overhead, build->id,
                stepNr, machine->sshName, result.stepStatus, result.errorMsg);
            txn.commit();
            if (quit) exit(1);
            return sRetry;
        }
    }

    if (result.stepStatus == bsSuccess) {

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
                    printMsg(lvlDebug, format("finishing build step ‘%1%’") % step->drvPath);
                    steps_->erase(step->drvPath);
                }
            }

            /* Update the database. */
            {
                auto mc = startDbUpdate();

                pqxx::work txn(*conn);

                finishBuildStep(txn, result.startTime, result.stopTime, result.overhead,
                    build->id, stepNr, machine->sshName, bsSuccess);

                for (auto & b : direct) {
                    printMsg(lvlInfo, format("marking build %1% as succeeded") % b->id);
                    markSucceededBuild(txn, b, res, build != b || result.isCached,
                        result.startTime, result.stopTime);
                }

                txn.commit();
            }

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
        for (auto id : buildIDs) {
            {
                auto notificationSenderQueue_(notificationSenderQueue.lock());
                notificationSenderQueue_->push(NotificationItem(id, std::vector<BuildID>()));
            }
            notificationSenderWakeup.notify_one();
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

    } else {

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
                        printMsg(lvlDebug, format("finishing build step ‘%1%’") % s->drvPath);
                        steps_->erase(s->drvPath);
                    }
                    break;
                }
            }

            /* Update the database. */
            {
                auto mc = startDbUpdate();

                pqxx::work txn(*conn);

                /* For standard failures, we don't care about the error
                   message. */
                if (result.stepStatus != bsAborted)
                    result.errorMsg = "";

                /* Create failed build steps for every build that
                   depends on this, except when this step is cached
                   and is the top-level of that build (since then it's
                   redundant with the build's isCachedBuild field). */
                for (auto & build2 : indirect) {
                    if ((result.stepStatus == bsCachedFailure && build2->drvPath == step->drvPath) ||
                        (result.stepStatus != bsCachedFailure && build == build2) ||
                        build2->finishedInDB)
                        continue;
                    createBuildStep(txn, 0, build2, step, machine->sshName,
                        result.stepStatus, result.errorMsg, build == build2 ? 0 : build->id);
                }

                if (result.stepStatus != bsCachedFailure)
                    finishBuildStep(txn, result.startTime, result.stopTime, result.overhead,
                        build->id, stepNr, machine->sshName, result.stepStatus, result.errorMsg);

                /* Mark all builds that depend on this derivation as failed. */
                for (auto & build2 : indirect) {
                    if (build2->finishedInDB) continue;
                    printMsg(lvlError, format("marking build %1% as failed") % build2->id);
                    txn.parameterized
                        ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $4, isCachedBuild = $5 where id = $1 and finished = 0")
                        (build2->id)
                        ((int) (build2->drvPath != step->drvPath && result.buildStatus() == bsFailed ? bsDepFailed : result.buildStatus()))
                        (result.startTime)
                        (result.stopTime)
                        (result.stepStatus == bsCachedFailure ? 1 : 0).exec();
                    nrBuildsDone++;
                }

                /* Remember failed paths in the database so that they
                   won't be built again. */
                if (result.stepStatus != bsCachedFailure && result.canCache)
                    for (auto & path : step->drv.outputPaths())
                        txn.parameterized("insert into FailedPaths values ($1)")(path).exec();

                txn.commit();
            }

            /* Remove the indirect dependencies from ‘builds’. This
               will cause them to be destroyed. */
            for (auto & b : indirect) {
                auto builds_(builds.lock());
                b->finishedInDB = true;
                builds_->erase(b->id);
                dependentIDs.push_back(b->id);
                if (buildOne == b->id) quit = true;
            }
        }

        /* Send notification about this build and its dependents. */
        {
            auto notificationSenderQueue_(notificationSenderQueue.lock());
            notificationSenderQueue_->push(NotificationItem(build->id, dependentIDs));
        }
        notificationSenderWakeup.notify_one();

    }

    // FIXME: keep stats about aborted steps?
    nrStepsDone++;
    totalStepTime += stepStopTime - stepStartTime;
    totalStepBuildTime += result.stopTime - result.startTime;
    machine->state->nrStepsDone++;
    machine->state->totalStepTime += stepStopTime - stepStartTime;
    machine->state->totalStepBuildTime += result.stopTime - result.startTime;

    if (quit) exit(0); // testing hack

    return sDone;
}

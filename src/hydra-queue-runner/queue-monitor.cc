#include "state.hh"
#include "hydra-build-result.hh"
#include "globals.hh"
#include "thread-pool.hh"

#include <cstring>

using namespace nix;


void State::queueMonitor()
{
    while (true) {
        auto conn(dbPool.get());
        try {
            queueMonitorLoop(*conn);
        } catch (pqxx::broken_connection & e) {
            printMsg(lvlError, "queue monitor: %s", e.what());
            printMsg(lvlError, "queue monitor: Reconnecting in 10s");
            conn.markBad();
            sleep(10);
        } catch (std::exception & e) {
            printError("queue monitor: %s", e.what());
            sleep(10); // probably a DB problem, so don't retry right away
        }
    }
}


void State::queueMonitorLoop(Connection & conn)
{
    receiver buildsAdded(conn, "builds_added");
    receiver buildsRestarted(conn, "builds_restarted");
    receiver buildsCancelled(conn, "builds_cancelled");
    receiver buildsDeleted(conn, "builds_deleted");
    receiver buildsBumped(conn, "builds_bumped");
    receiver jobsetSharesChanged(conn, "jobset_shares_changed");

    auto destStore = getDestStore();

    bool quit = false;
    while (!quit) {
        auto t_before_work = std::chrono::steady_clock::now();

        localStore->clearPathInfoCache();

        bool done = getQueuedBuilds(conn, destStore);

        if (buildOne && buildOneDone) quit = true;

        auto t_after_work = std::chrono::steady_clock::now();

        prom.queue_monitor_time_spent_running.Increment(
            std::chrono::duration_cast<std::chrono::microseconds>(t_after_work - t_before_work).count());

        /* Sleep until we get notification from the database about an
           event. */
        if (done && !quit) {
            conn.await_notification();
            nrQueueWakeups++;
        } else
            conn.get_notifs();

        if (auto lowestId = buildsAdded.get()) {
            printMsg(lvlTalkative, "got notification: new builds added to the queue");
        }
        if (buildsRestarted.get()) {
            printMsg(lvlTalkative, "got notification: builds restarted");
        }
        if (buildsCancelled.get() || buildsDeleted.get() || buildsBumped.get()) {
            printMsg(lvlTalkative, "got notification: builds cancelled or bumped");
            processQueueChange(conn);
        }
        if (jobsetSharesChanged.get()) {
            printMsg(lvlTalkative, "got notification: jobset shares changed");
            processJobsetSharesChange(conn);
        }

        auto t_after_sleep = std::chrono::steady_clock::now();
        prom.queue_monitor_time_spent_waiting.Increment(
            std::chrono::duration_cast<std::chrono::microseconds>(t_after_sleep - t_after_work).count());
    }

    exit(0);
}


struct PreviousFailure : public std::exception {
    Step::ptr step;
    PreviousFailure(Step::ptr step) : step(step) { }
};


bool State::getQueuedBuilds(Connection & conn,
    ref<Store> destStore)
{
    prom.queue_checks_started.Increment();

    printInfo("checking the queue for builds...");

    /* Grab the queued builds from the database, but don't process
       them yet (since we don't want a long-running transaction). */
    std::vector<BuildID> newIDs;
    std::unordered_map<BuildID, Build::ptr> newBuildsByID;
    std::multimap<StorePath, BuildID> newBuildsByPath;

    {
        pqxx::work txn(conn);

        auto res = txn.exec_params
            ("select builds.id, builds.jobset_id, jobsets.project as project, "
             "jobsets.name as jobset, job, drvPath, maxsilent, timeout, timestamp, "
             "globalPriority, priority from Builds "
             "inner join jobsets on builds.jobset_id = jobsets.id "
             "where finished = 0 order by globalPriority desc, random()");

        for (auto const & row : res) {
            auto builds_(builds.lock());
            BuildID id = row["id"].as<BuildID>();
            if (buildOne && id != buildOne) continue;
            if (builds_->count(id)) continue;

            auto build = std::make_shared<Build>(
                localStore->parseStorePath(row["drvPath"].as<std::string>()));
            build->id = id;
            build->jobsetId = row["jobset_id"].as<JobsetID>();
            build->projectName = row["project"].as<std::string>();
            build->jobsetName = row["jobset"].as<std::string>();
            build->jobName = row["job"].as<std::string>();
            build->maxSilentTime = row["maxsilent"].as<int>();
            build->buildTimeout = row["timeout"].as<int>();
            build->timestamp = row["timestamp"].as<time_t>();
            build->globalPriority = row["globalPriority"].as<int>();
            build->localPriority = row["priority"].as<int>();
            build->jobset = createJobset(txn, build->projectName, build->jobsetName, build->jobsetId);

            newIDs.push_back(id);
            newBuildsByID[id] = build;
            newBuildsByPath.emplace(std::make_pair(build->drvPath, id));
        }
    }

    std::set<Step::ptr> newRunnable;
    unsigned int nrAdded;
    std::function<void(Build::ptr)> createBuild;
    std::set<StorePath> finishedDrvs;

    createBuild = [&](Build::ptr build) {
        prom.queue_build_loads.Increment();
        printMsg(lvlTalkative, "loading build %1% (%2%)", build->id, build->fullJobName());
        nrAdded++;
        newBuildsByID.erase(build->id);

        if (!localStore->isValidPath(build->drvPath)) {
            /* Derivation has been GC'ed prematurely. */
            printError("aborting GC'ed build %1%", build->id);
            if (!build->finishedInDB) {
                auto mc = startDbUpdate();
                pqxx::work txn(conn);
                txn.exec_params0
                    ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $3 where id = $1 and finished = 0",
                     build->id,
                     (int) bsAborted,
                     time(0));
                txn.commit();
                build->finishedInDB = true;
                nrBuildsDone++;
            }
            return;
        }

        std::set<Step::ptr> newSteps;
        Step::ptr step;

        /* Create steps for this derivation and its dependencies. */
        try {
            step = createStep(destStore, conn, build, build->drvPath,
                build, 0, finishedDrvs, newSteps, newRunnable);
        } catch (PreviousFailure & ex) {

            /* Some step previously failed, so mark the build as
               failed right away. */
            if (!buildOneDone && build->id == buildOne) buildOneDone = true;
            printMsg(lvlError, "marking build %d as cached failure due to ‘%s’",
                build->id, localStore->printStorePath(ex.step->drvPath));
            if (!build->finishedInDB) {
                auto mc = startDbUpdate();
                pqxx::work txn(conn);

                /* Find the previous build step record, first by
                   derivation path, then by output path. */
                BuildID propagatedFrom = 0;

                auto res = txn.exec_params1
                    ("select max(build) from BuildSteps where drvPath = $1 and startTime != 0 and stopTime != 0 and status = 1",
                     localStore->printStorePath(ex.step->drvPath));
                if (!res[0].is_null()) propagatedFrom = res[0].as<BuildID>();

                if (!propagatedFrom) {
                    for (auto & [outputName, optOutputPath] : destStore->queryPartialDerivationOutputMap(ex.step->drvPath, &*localStore)) {
                        constexpr std::string_view common = "select max(s.build) from BuildSteps s join BuildStepOutputs o on s.build = o.build where startTime != 0 and stopTime != 0 and status = 1";
                        auto res = optOutputPath
                            ? txn.exec_params(
                                std::string { common } + " and path = $1",
                                localStore->printStorePath(*optOutputPath))
                            : txn.exec_params(
                                std::string { common } + " and drvPath = $1 and name = $2",
                                localStore->printStorePath(ex.step->drvPath),
                                outputName);
                        if (!res[0][0].is_null()) {
                            propagatedFrom = res[0][0].as<BuildID>();
                            break;
                        }
                    }
                }

                createBuildStep(txn, 0, build->id, ex.step, "", bsCachedFailure, "", propagatedFrom);
                txn.exec_params
                    ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $3, isCachedBuild = 1, notificationPendingSince = $3 "
                     "where id = $1 and finished = 0",
                     build->id,
                     (int) (ex.step->drvPath == build->drvPath ? bsFailed : bsDepFailed),
                     time(0));
                notifyBuildFinished(txn, build->id, {});
                txn.commit();
                build->finishedInDB = true;
                nrBuildsDone++;
            }

            return;
        }

        /* Some of the new steps may be the top level of builds that
           we haven't processed yet. So do them now. This ensures that
           if build A depends on build B with top-level step X, then X
           will be "accounted" to B in doBuildStep(). */
        for (auto & r : newSteps) {
            auto i = newBuildsByPath.find(r->drvPath);
            if (i == newBuildsByPath.end()) continue;
            auto j = newBuildsByID.find(i->second);
            if (j == newBuildsByID.end()) continue;
            createBuild(j->second);
        }

        /* If we didn't get a step, it means the step's outputs are
           all valid. So we mark this as a finished, cached build. */
        if (!step) {
            BuildOutput res = getBuildOutputCached(conn, destStore, build->drvPath);

            for (auto & i : destStore->queryDerivationOutputMap(build->drvPath, &*localStore))
                addRoot(i.second);

            {
            auto mc = startDbUpdate();
            pqxx::work txn(conn);
            time_t now = time(0);
            if (!buildOneDone && build->id == buildOne) buildOneDone = true;
            printMsg(lvlInfo, "marking build %1% as succeeded (cached)", build->id);
            markSucceededBuild(txn, build, res, true, now, now);
            notifyBuildFinished(txn, build->id, {});
            txn.commit();
            }

            build->finishedInDB = true;

            return;
        }

        /* Note: if we exit this scope prior to this, the build and
           all newly created steps are destroyed. */

        {
            auto builds_(builds.lock());
            if (!build->finishedInDB) // FIXME: can this happen?
                (*builds_)[build->id] = build;
            build->toplevel = step;
        }

        build->propagatePriorities();

        printMsg(lvlChatty, "added build %1% (top-level step %2%, %3% new steps)",
            build->id, localStore->printStorePath(step->drvPath), newSteps.size());
    };

    /* Now instantiate build steps for each new build. The builder
       threads can start building the runnable build steps right away,
       even while we're still processing other new builds. */
    system_time start = std::chrono::system_clock::now();

    for (auto id : newIDs) {
        auto i = newBuildsByID.find(id);
        if (i == newBuildsByID.end()) continue;
        auto build = i->second;

        auto now1 = std::chrono::steady_clock::now();

        newRunnable.clear();
        nrAdded = 0;
        try {
            createBuild(build);
        } catch (Error & e) {
            e.addTrace({}, HintFmt("while loading build %d: ", build->id));
            throw;
        }

        auto now2 = std::chrono::steady_clock::now();

        buildReadTimeMs += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();

        /* Add the new runnable build steps to ‘runnable’ and wake up
           the builder threads. */
        printMsg(lvlChatty, "got %1% new runnable steps from %2% new builds", newRunnable.size(), nrAdded);
        for (auto & r : newRunnable)
            makeRunnable(r);

        if (buildOne && newRunnable.size() == 0) buildOneDone = true;

        nrBuildsRead += nrAdded;

        /* Stop after a certain time to allow priority bumps to be
           processed. */
        if (std::chrono::system_clock::now() > start + std::chrono::seconds(60)) {
            prom.queue_checks_early_exits.Increment();
            break;
        }
    }

    prom.queue_checks_finished.Increment();
    return newBuildsByID.empty();
}


void Build::propagatePriorities()
{
    /* Update the highest global priority and lowest build ID fields
       of each dependency. This is used by the dispatcher to start
       steps in order of descending global priority and ascending
       build ID. */
    visitDependencies([&](const Step::ptr & step) {
        auto step_(step->state.lock());
        step_->highestGlobalPriority = std::max(step_->highestGlobalPriority, globalPriority);
        step_->highestLocalPriority = std::max(step_->highestLocalPriority, localPriority);
        step_->lowestBuildID = std::min(step_->lowestBuildID, id);
        step_->jobsets.insert(jobset);
    }, toplevel);
}


void State::processQueueChange(Connection & conn)
{
    /* Get the current set of queued builds. */
    std::map<BuildID, int> currentIds;
    {
        pqxx::work txn(conn);
        auto res = txn.exec("select id, globalPriority from Builds where finished = 0");
        for (auto const & row : res)
            currentIds[row["id"].as<BuildID>()] = row["globalPriority"].as<BuildID>();
    }

    {
        auto builds_(builds.lock());

        for (auto i = builds_->begin(); i != builds_->end(); ) {
            auto b = currentIds.find(i->first);
            if (b == currentIds.end()) {
                printInfo("discarding cancelled build %1%", i->first);
                i = builds_->erase(i);
                // FIXME: ideally we would interrupt active build steps here.
                continue;
            }
            if (i->second->globalPriority < b->second) {
                printInfo("priority of build %1% increased", i->first);
                i->second->globalPriority = b->second;
                i->second->propagatePriorities();
            }
            ++i;
        }
    }

    {
        auto activeSteps(activeSteps_.lock());
        for (auto & activeStep : *activeSteps) {
            std::set<Build::ptr> dependents;
            std::set<Step::ptr> steps;
            getDependents(activeStep->step, dependents, steps);
            if (!dependents.empty()) continue;

            {
                auto activeStepState(activeStep->state_.lock());
                if (activeStepState->cancelled) continue;
                activeStepState->cancelled = true;
                if (activeStepState->pid != -1) {
                    printInfo("killing builder process %d of build step ‘%s’",
                        activeStepState->pid,
                        localStore->printStorePath(activeStep->step->drvPath));
                    if (kill(activeStepState->pid, SIGINT) == -1)
                        printError("error killing build step ‘%s’: %s",
                            localStore->printStorePath(activeStep->step->drvPath),
                            strerror(errno));
                }
            }
        }
    }
}


std::map<DrvOutput, std::optional<StorePath>> State::getMissingRemotePaths(
    ref<Store> destStore,
    const std::map<DrvOutput, std::optional<StorePath>> & paths)
{
    Sync<std::map<DrvOutput, std::optional<StorePath>>> missing_;
    ThreadPool tp;

    for (auto & [output, maybeOutputPath] : paths) {
        if (!maybeOutputPath) {
            auto missing(missing_.lock());
            missing->insert({output, maybeOutputPath});
        } else {
            tp.enqueue([&] {
                if (!destStore->isValidPath(*maybeOutputPath)) {
                    auto missing(missing_.lock());
                    missing->insert({output, maybeOutputPath});
                }
            });
        }
    }

    tp.process();

    auto missing(missing_.lock());
    return *missing;
}


Step::ptr State::createStep(ref<Store> destStore,
    Connection & conn, Build::ptr build, const StorePath & drvPath,
    Build::ptr referringBuild, Step::ptr referringStep, std::set<StorePath> & finishedDrvs,
    std::set<Step::ptr> & newSteps, std::set<Step::ptr> & newRunnable)
{
    if (finishedDrvs.find(drvPath) != finishedDrvs.end()) return 0;

    /* Check if the requested step already exists. If not, create a
       new step. In any case, make the step reachable from
       referringBuild or referringStep. This is done atomically (with
       ‘steps’ locked), to ensure that this step can never become
       reachable from a new build after doBuildStep has removed it
       from ‘steps’. */
    Step::ptr step;
    bool isNew = false;
    {
        auto steps_(steps.lock());

        /* See if the step already exists in ‘steps’ and is not
           stale. */
        auto prev = steps_->find(drvPath);
        if (prev != steps_->end()) {
            step = prev->second.lock();
            /* Since ‘step’ is a strong pointer, the referred Step
               object won't be deleted after this. */
            if (!step) steps_->erase(drvPath); // remove stale entry
        }

        /* If it doesn't exist, create it. */
        if (!step) {
            step = std::make_shared<Step>(drvPath);
            isNew = true;
        }

        auto step_(step->state.lock());

        assert(step_->created != isNew);

        if (referringBuild)
            step_->builds.push_back(referringBuild);

        if (referringStep)
            step_->rdeps.push_back(referringStep);

        steps_->insert_or_assign(drvPath, step);
    }

    if (!isNew) return step;

    prom.queue_steps_created.Increment();

    printMsg(lvlDebug, "considering derivation ‘%1%’", localStore->printStorePath(drvPath));

    /* Initialize the step. Note that the step may be visible in
       ‘steps’ before this point, but that doesn't matter because
       it's not runnable yet, and other threads won't make it
       runnable while step->created == false. */
    step->drv = std::make_unique<Derivation>(localStore->readDerivation(drvPath));
    step->parsedDrv = std::make_unique<ParsedDerivation>(drvPath, *step->drv);

    step->preferLocalBuild = step->parsedDrv->willBuildLocally(*localStore);
    step->isDeterministic = getOr(step->drv->env, "isDetermistic", "0") == "1";

    step->systemType = step->drv->platform;
    {
        StringSet features = step->requiredSystemFeatures = step->parsedDrv->getRequiredSystemFeatures();
        if (step->preferLocalBuild)
            features.insert("local");
        if (!features.empty()) {
            step->systemType += ":";
            step->systemType += concatStringsSep(",", features);
        }
    }

    /* If this derivation failed previously, give up. */
    if (checkCachedFailure(step, conn))
        throw PreviousFailure{step};

    /* Are all outputs valid? */
    auto outputHashes = staticOutputHashes(*localStore, *(step->drv));
    std::map<DrvOutput, std::optional<StorePath>> paths;
    for (auto & [outputName, maybeOutputPath] : destStore->queryPartialDerivationOutputMap(drvPath, &*localStore)) {
        auto outputHash = outputHashes.at(outputName);
        paths.insert({{outputHash, outputName}, maybeOutputPath});
    }

    auto missing = getMissingRemotePaths(destStore, paths);
    bool valid = missing.empty();

    /* Try to copy the missing paths from the local store or from
       substitutes. */
    if (!missing.empty()) {

        size_t avail = 0;
        for (auto & [i, pathOpt] : missing) {
            // If we don't know the output path from the destination
            // store, see if the local store can tell us.
            if (/* localStore != destStore && */ !pathOpt && experimentalFeatureSettings.isEnabled(Xp::CaDerivations))
                if (auto maybeRealisation = localStore->queryRealisation(i))
                    pathOpt = maybeRealisation->outPath;

            if (!pathOpt) {
                // No hope of getting the store object if we don't know
                // the path.
                continue;
            }
            auto & path = *pathOpt;

            if (/* localStore != destStore && */ localStore->isValidPath(path))
                avail++;
            else if (useSubstitutes) {
                SubstitutablePathInfos infos;
                localStore->querySubstitutablePathInfos({{path, {}}}, infos);
                if (infos.size() == 1)
                    avail++;
            }
        }

        if (missing.size() == avail) {
            valid = true;
            for (auto & [i, pathOpt] : missing) {
                // If we found everything, then we should know the path
                // to every missing store object now.
                assert(pathOpt);
                auto & path = *pathOpt;

                try {
                    time_t startTime = time(0);

                    if (localStore->isValidPath(path))
                        printInfo("copying output ‘%1%’ of ‘%2%’ from local store",
                            localStore->printStorePath(path),
                            localStore->printStorePath(drvPath));
                    else {
                        printInfo("substituting output ‘%1%’ of ‘%2%’",
                            localStore->printStorePath(path),
                            localStore->printStorePath(drvPath));
                        localStore->ensurePath(path);
                        // FIXME: should copy directly from substituter to destStore.
                    }

                    copyClosure(*localStore, *destStore,
                        StorePathSet { path },
                        NoRepair, CheckSigs, NoSubstitute);

                    time_t stopTime = time(0);

                    {
                        auto mc = startDbUpdate();
                        pqxx::work txn(conn);
                        createSubstitutionStep(txn, startTime, stopTime, build, drvPath, *(step->drv), "out", path);
                        txn.commit();
                    }

                } catch (Error & e) {
                    printError("while copying/substituting output ‘%s’ of ‘%s’: %s",
                        localStore->printStorePath(path),
                        localStore->printStorePath(drvPath),
                        e.what());
                    valid = false;
                    break;
                }
            }
        }
    }

    // FIXME: check whether all outputs are in the binary cache.
    if (valid) {
        finishedDrvs.insert(drvPath);
        return 0;
    }

    /* No, we need to build. */
    printMsg(lvlDebug, "creating build step ‘%1%’", localStore->printStorePath(drvPath));

    /* Create steps for the dependencies. */
    for (auto & i : step->drv->inputDrvs.map) {
        auto dep = createStep(destStore, conn, build, i.first, 0, step, finishedDrvs, newSteps, newRunnable);
        if (dep) {
            auto step_(step->state.lock());
            step_->deps.insert(dep);
        }
    }

    /* If the step has no (remaining) dependencies, make it
       runnable. */
    {
        auto step_(step->state.lock());
        assert(!step_->created);
        step_->created = true;
        if (step_->deps.empty())
            newRunnable.insert(step);
    }

    newSteps.insert(step);

    return step;
}


Jobset::ptr State::createJobset(pqxx::work & txn,
    const std::string & projectName, const std::string & jobsetName, const JobsetID jobsetID)
{
    auto p = std::make_pair(projectName, jobsetName);

    {
        auto jobsets_(jobsets.lock());
        auto i = jobsets_->find(p);
        if (i != jobsets_->end()) return i->second;
    }

    auto res = txn.exec_params1
        ("select schedulingShares from Jobsets where id = $1",
         jobsetID);
    if (res.empty()) throw Error("missing jobset - can't happen");

    auto shares = res["schedulingShares"].as<unsigned int>();

    auto jobset = std::make_shared<Jobset>();
    jobset->setShares(shares);

    /* Load the build steps from the last 24 hours. */
    auto res2 = txn.exec_params
        ("select s.startTime, s.stopTime from BuildSteps s join Builds b on build = id "
         "where s.startTime is not null and s.stopTime > $1 and jobset_id = $2",
         time(0) - Jobset::schedulingWindow * 10,
         jobsetID);
    for (auto const & row : res2) {
        time_t startTime = row["startTime"].as<time_t>();
        time_t stopTime = row["stopTime"].as<time_t>();
        jobset->addStep(startTime, stopTime - startTime);
    }

    auto jobsets_(jobsets.lock());
    // Can't happen because only this thread adds to "jobsets".
    assert(jobsets_->find(p) == jobsets_->end());
    (*jobsets_)[p] = jobset;
    return jobset;
}


void State::processJobsetSharesChange(Connection & conn)
{
    /* Get the current set of jobsets. */
    pqxx::work txn(conn);
    auto res = txn.exec("select project, name, schedulingShares from Jobsets");
    for (auto const & row : res) {
        auto jobsets_(jobsets.lock());
        auto i = jobsets_->find(std::make_pair(row["project"].as<std::string>(), row["name"].as<std::string>()));
        if (i == jobsets_->end()) continue;
        i->second->setShares(row["schedulingShares"].as<unsigned int>());
    }
}


BuildOutput State::getBuildOutputCached(Connection & conn, nix::ref<nix::Store> destStore, const nix::StorePath & drvPath)
{
    auto derivationOutputs = destStore->queryDerivationOutputMap(drvPath, &*localStore);

    {
    pqxx::work txn(conn);

    for (auto & [name, output] : derivationOutputs) {
        auto r = txn.exec_params
            ("select id, buildStatus, releaseName, closureSize, size from Builds b "
             "join BuildOutputs o on b.id = o.build "
             "where finished = 1 and (buildStatus = 0 or buildStatus = 6) and path = $1",
             localStore->printStorePath(output));
        if (r.empty()) continue;
        BuildID id = r[0][0].as<BuildID>();

        printInfo("reusing build %d", id);

        BuildOutput res;
        res.failed = r[0][1].as<int>() == bsFailedWithOutput;
        res.releaseName = r[0][2].is_null() ? "" : r[0][2].as<std::string>();
        res.closureSize = r[0][3].is_null() ? 0 : r[0][3].as<uint64_t>();
        res.size = r[0][4].is_null() ? 0 : r[0][4].as<uint64_t>();

        auto products = txn.exec_params
            ("select type, subtype, fileSize, sha256hash, path, name, defaultPath from BuildProducts where build = $1 order by productnr",
             id);

        for (auto row : products) {
            BuildProduct product;
            product.type = row[0].as<std::string>();
            product.subtype = row[1].as<std::string>();
            if (row[2].is_null())
                product.isRegular = false;
            else {
                product.isRegular = true;
                product.fileSize = row[2].as<off_t>();
            }
            if (!row[3].is_null())
                product.sha256hash = Hash::parseAny(row[3].as<std::string>(), HashAlgorithm::SHA256);
            if (!row[4].is_null())
                product.path = row[4].as<std::string>();
            product.name = row[5].as<std::string>();
            if (!row[6].is_null())
                product.defaultPath = row[6].as<std::string>();
            res.products.emplace_back(product);
        }

        auto metrics = txn.exec_params
            ("select name, unit, value from BuildMetrics where build = $1",
             id);

        for (auto row : metrics) {
            BuildMetric metric;
            metric.name = row[0].as<std::string>();
            metric.unit = row[1].is_null() ? "" : row[1].as<std::string>();
            metric.value = row[2].as<double>();
            res.metrics.emplace(metric.name, metric);
        }

        return res;
    }

    }

    NarMemberDatas narMembers;
    return getBuildOutput(destStore, narMembers, derivationOutputs);
}

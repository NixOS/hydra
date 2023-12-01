#include <iostream>
#include <thread>
#include <optional>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include <prometheus/exposer.h>

#include <nlohmann/json.hpp>

#include "signals.hh"
#include "state.hh"
#include "hydra-build-result.hh"
#include "store-api.hh"
#include "remote-store.hh"

#include "globals.hh"
#include "hydra-config.hh"
#include "s3-binary-cache-store.hh"
#include "shared.hh"

using namespace nix;
using nlohmann::json;


std::string getEnvOrDie(const std::string & key)
{
    auto value = getEnv(key);
    if (!value) throw Error("environment variable '%s' is not set", key);
    return *value;
}

State::PromMetrics::PromMetrics()
    : registry(std::make_shared<prometheus::Registry>())
    , queue_checks_started(
        prometheus::BuildCounter()
            .Name("hydraqueuerunner_queue_checks_started_total")
            .Help("Number of times State::getQueuedBuilds() was started")
            .Register(*registry)
            .Add({})
    )
    , queue_build_loads(
        prometheus::BuildCounter()
            .Name("hydraqueuerunner_queue_build_loads_total")
            .Help("Number of builds loaded")
            .Register(*registry)
            .Add({})
    )
    , queue_steps_created(
        prometheus::BuildCounter()
            .Name("hydraqueuerunner_queue_steps_created_total")
            .Help("Number of steps created")
            .Register(*registry)
            .Add({})
    )
    , queue_checks_early_exits(
        prometheus::BuildCounter()
            .Name("hydraqueuerunner_queue_checks_early_exits_total")
            .Help("Number of times State::getQueuedBuilds() yielded to potential bumps")
            .Register(*registry)
            .Add({})
    )
    , queue_checks_finished(
        prometheus::BuildCounter()
            .Name("hydraqueuerunner_queue_checks_finished_total")
            .Help("Number of times State::getQueuedBuilds() was completed")
            .Register(*registry)
            .Add({})
    )
    , queue_max_id(
        prometheus::BuildGauge()
            .Name("hydraqueuerunner_queue_max_build_id_info")
            .Help("Maximum build record ID in the queue")
            .Register(*registry)
            .Add({})
    )
{

}

State::State(std::optional<std::string> metricsAddrOpt)
    : config(std::make_unique<HydraConfig>())
    , maxUnsupportedTime(config->getIntOption("max_unsupported_time", 0))
    , dbPool(config->getIntOption("max_db_connections", 128))
    , maxOutputSize(config->getIntOption("max_output_size", 2ULL << 30))
    , maxLogSize(config->getIntOption("max_log_size", 64ULL << 20))
    , uploadLogsToBinaryCache(config->getBoolOption("upload_logs_to_binary_cache", false))
    , rootsDir(config->getStrOption("gc_roots_dir", fmt("%s/gcroots/per-user/%s/hydra-roots", settings.nixStateDir, getEnvOrDie("LOGNAME"))))
    , metricsAddr(config->getStrOption("queue_runner_metrics_address", std::string{"127.0.0.1:9198"}))
{
    hydraData = getEnvOrDie("HYDRA_DATA");

    logDir = canonPath(hydraData + "/build-logs");

    if (metricsAddrOpt.has_value()) {
        metricsAddr = metricsAddrOpt.value();
    }

    /* handle deprecated store specification */
    if (config->getStrOption("store_mode") != "")
        throw Error("store_mode in hydra.conf is deprecated, please use store_uri");
    if (config->getStrOption("binary_cache_dir") != "")
        printMsg(lvlError, "hydra.conf: binary_cache_dir is deprecated and ignored. use store_uri=file:// instead");
    if (config->getStrOption("binary_cache_s3_bucket") != "")
        printMsg(lvlError, "hydra.conf: binary_cache_s3_bucket is deprecated and ignored. use store_uri=s3:// instead");
    if (config->getStrOption("binary_cache_secret_key_file") != "")
        printMsg(lvlError, "hydra.conf: binary_cache_secret_key_file is deprecated and ignored. use store_uri=...?secret-key= instead");

    createDirs(rootsDir);
}


nix::MaintainCount<counter> State::startDbUpdate()
{
    if (nrActiveDbUpdates > 6)
        printError("warning: %d concurrent database updates; PostgreSQL may be stalled", nrActiveDbUpdates.load());
    return MaintainCount<counter>(nrActiveDbUpdates);
}


ref<Store> State::getDestStore()
{
    return ref<Store>(_destStore);
}


void State::parseMachines(const std::string & contents)
{
    Machines newMachines, oldMachines;
    {
        auto machines_(machines.lock());
        oldMachines = *machines_;
    }

    for (auto line : tokenizeString<Strings>(contents, "\n")) {
        line = trim(std::string(line, 0, line.find('#')));
        auto tokens = tokenizeString<std::vector<std::string>>(line);
        if (tokens.size() < 3) continue;
        tokens.resize(8);

        auto machine = std::make_shared<Machine>();
        machine->sshName = tokens[0];
        machine->systemTypes = tokenizeString<StringSet>(tokens[1], ",");
        machine->sshKey = tokens[2] == "-" ? std::string("") : tokens[2];
        if (tokens[3] != "")
            machine->maxJobs = string2Int<decltype(machine->maxJobs)>(tokens[3]).value();
        else
            machine->maxJobs = 1;
        machine->speedFactor = atof(tokens[4].c_str());
        if (tokens[5] == "-") tokens[5] = "";
        machine->supportedFeatures = tokenizeString<StringSet>(tokens[5], ",");
        if (tokens[6] == "-") tokens[6] = "";
        machine->mandatoryFeatures = tokenizeString<StringSet>(tokens[6], ",");
        for (auto & f : machine->mandatoryFeatures)
            machine->supportedFeatures.insert(f);
        if (tokens[7] != "" && tokens[7] != "-")
            machine->sshPublicHostKey = base64Decode(tokens[7]);

        /* Re-use the State object of the previous machine with the
           same name. */
        auto i = oldMachines.find(machine->sshName);
        if (i == oldMachines.end())
            printMsg(lvlChatty, "adding new machine ‘%1%’", machine->sshName);
        else
            printMsg(lvlChatty, "updating machine ‘%1%’", machine->sshName);
        machine->state = i == oldMachines.end()
            ? std::make_shared<Machine::State>()
            : i->second->state;
        newMachines[machine->sshName] = machine;
    }

    for (auto & m : oldMachines)
        if (newMachines.find(m.first) == newMachines.end()) {
            if (m.second->enabled)
                printInfo("removing machine ‘%1%’", m.first);
            /* Add a disabled Machine object to make sure stats are
               maintained. */
            auto machine = std::make_shared<Machine>(*(m.second));
            machine->enabled = false;
            newMachines[m.first] = machine;
        }

    static bool warned = false;
    if (newMachines.empty() && !warned) {
        printError("warning: no build machines are defined");
        warned = true;
    }

    auto machines_(machines.lock());
    *machines_ = newMachines;

    wakeDispatcher();
}


void State::monitorMachinesFile()
{
    std::string defaultMachinesFile = "/etc/nix/machines";
    auto machinesFiles = tokenizeString<std::vector<Path>>(
        getEnv("NIX_REMOTE_SYSTEMS").value_or(pathExists(defaultMachinesFile) ? defaultMachinesFile : ""), ":");

    if (machinesFiles.empty()) {
        parseMachines("localhost " +
            (settings.thisSystem == "x86_64-linux" ? "x86_64-linux,i686-linux" : settings.thisSystem.get())
            + " - " + std::to_string(settings.maxBuildJobs) + " 1 "
            + concatStringsSep(",", settings.systemFeatures.get()));
        machinesReadyLock.unlock();
        return;
    }

    std::vector<struct stat> fileStats;
    fileStats.resize(machinesFiles.size());
    for (unsigned int n = 0; n < machinesFiles.size(); ++n) {
        auto & st(fileStats[n]);
        st.st_ino = st.st_mtime = 0;
    }

    auto readMachinesFiles = [&]() {

        /* Check if any of the machines files changed. */
        bool anyChanged = false;
        for (unsigned int n = 0; n < machinesFiles.size(); ++n) {
            Path machinesFile = machinesFiles[n];
            struct stat st;
            if (stat(machinesFile.c_str(), &st) != 0) {
                if (errno != ENOENT)
                    throw SysError("getting stats about ‘%s’", machinesFile);
                st.st_ino = st.st_mtime = 0;
            }
            auto & old(fileStats[n]);
            if (old.st_ino != st.st_ino || old.st_mtime != st.st_mtime)
                anyChanged = true;
            old = st;
        }

        if (!anyChanged) return;

        debug("reloading machines files");

        std::string contents;
        for (auto & machinesFile : machinesFiles) {
            try {
                contents += readFile(machinesFile);
                contents += '\n';
            } catch (SysError & e) {
                if (e.errNo != ENOENT) throw;
            }
        }

        parseMachines(contents);
    };

    auto firstParse = true;

    while (true) {
        try {
            readMachinesFiles();
            if (firstParse) {
                machinesReadyLock.unlock();
                firstParse = false;
            }
            // FIXME: use inotify.
            sleep(30);
        } catch (std::exception & e) {
            printMsg(lvlError, "reloading machines file: %s", e.what());
            sleep(5);
        }
    }
}


void State::clearBusy(Connection & conn, time_t stopTime)
{
    pqxx::work txn(conn);
    txn.exec_params0
        ("update BuildSteps set busy = 0, status = $1, stopTime = $2 where busy != 0",
         (int) bsAborted,
         stopTime != 0 ? std::make_optional(stopTime) : std::nullopt);
    txn.commit();
}


unsigned int State::allocBuildStep(pqxx::work & txn, BuildID buildId)
{
    auto res = txn.exec_params1("select max(stepnr) from BuildSteps where build = $1", buildId);
    return res[0].is_null() ? 1 : res[0].as<int>() + 1;
}


unsigned int State::createBuildStep(pqxx::work & txn, time_t startTime, BuildID buildId, Step::ptr step,
    const std::string & machine, BuildStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
 restart:
    auto stepNr = allocBuildStep(txn, buildId);

    auto r = txn.exec_params
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, startTime, system, status, propagatedFrom, errorMsg, stopTime, machine) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) on conflict do nothing",
         buildId,
         stepNr,
         0, // == build
         localStore->printStorePath(step->drvPath),
         status == bsBusy ? 1 : 0,
         startTime != 0 ? std::make_optional(startTime) : std::nullopt,
         step->drv->platform,
         status != bsBusy ? std::make_optional((int) status) : std::nullopt,
         propagatedFrom != 0 ? std::make_optional(propagatedFrom) : std::nullopt, // internal::params
         errorMsg != "" ? std::make_optional(errorMsg) : std::nullopt,
         startTime != 0 && status != bsBusy ? std::make_optional(startTime) : std::nullopt,
         machine);

    if (r.affected_rows() == 0) goto restart;

    for (auto & [name, output] : step->drv->outputs)
        txn.exec_params0
            ("insert into BuildStepOutputs (build, stepnr, name, path) values ($1, $2, $3, $4)",
            buildId, stepNr, name, localStore->printStorePath(*output.path(*localStore, step->drv->name, name)));

    if (status == bsBusy)
        txn.exec(fmt("notify step_started, '%d\t%d'", buildId, stepNr));

    return stepNr;
}


void State::updateBuildStep(pqxx::work & txn, BuildID buildId, unsigned int stepNr, StepState stepState)
{
    if (txn.exec_params
        ("update BuildSteps set busy = $1 where build = $2 and stepnr = $3 and busy != 0 and status is null",
         (int) stepState,
         buildId,
         stepNr).affected_rows() != 1)
        throw Error("step %d of build %d is in an unexpected state", stepNr, buildId);
}


void State::finishBuildStep(pqxx::work & txn, const RemoteResult & result,
    BuildID buildId, unsigned int stepNr, const std::string & machine)
{
    assert(result.startTime);
    assert(result.stopTime);
    txn.exec_params0
        ("update BuildSteps set busy = 0, status = $1, errorMsg = $4, startTime = $5, stopTime = $6, machine = $7, overhead = $8, timesBuilt = $9, isNonDeterministic = $10 where build = $2 and stepnr = $3",
         (int) result.stepStatus, buildId, stepNr,
         result.errorMsg != "" ? std::make_optional(result.errorMsg) : std::nullopt,
         result.startTime, result.stopTime,
         machine != "" ? std::make_optional(machine) : std::nullopt,
         result.overhead != 0 ? std::make_optional(result.overhead) : std::nullopt,
         result.timesBuilt > 0 ? std::make_optional(result.timesBuilt) : std::nullopt,
         result.timesBuilt > 1 ? std::make_optional(result.isNonDeterministic) : std::nullopt);
    assert(result.logFile.find('\t') == std::string::npos);
    txn.exec(fmt("notify step_finished, '%d\t%d\t%s'",
            buildId, stepNr, result.logFile));
}


int State::createSubstitutionStep(pqxx::work & txn, time_t startTime, time_t stopTime,
    Build::ptr build, const StorePath & drvPath, const std::string & outputName, const StorePath & storePath)
{
 restart:
    auto stepNr = allocBuildStep(txn, build->id);

    auto r = txn.exec_params
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, status, startTime, stopTime) values ($1, $2, $3, $4, $5, $6, $7, $8) on conflict do nothing",
         build->id,
         stepNr,
         1, // == substitution
         (localStore->printStorePath(drvPath)),
         0,
         0,
         startTime,
         stopTime);

    if (r.affected_rows() == 0) goto restart;

    txn.exec_params0
        ("insert into BuildStepOutputs (build, stepnr, name, path) values ($1, $2, $3, $4)",
         build->id, stepNr, outputName,
         localStore->printStorePath(storePath));

    return stepNr;
}


/* Get the steps and unfinished builds that depend on the given step. */
void getDependents(Step::ptr step, std::set<Build::ptr> & builds, std::set<Step::ptr> & steps)
{
    std::function<void(Step::ptr)> visit;

    visit = [&](Step::ptr step) {
        if (steps.count(step)) return;
        steps.insert(step);

        std::vector<Step::wptr> rdeps;

        {
            auto step_(step->state.lock());

            for (auto & build : step_->builds) {
                auto build_ = build.lock();
                if (build_ && !build_->finishedInDB) builds.insert(build_);
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
}


void visitDependencies(std::function<void(Step::ptr)> visitor, Step::ptr start)
{
    std::set<Step::ptr> queued;
    std::queue<Step::ptr> todo;
    todo.push(start);

    while (!todo.empty()) {
        auto step = todo.front();
        todo.pop();

        visitor(step);

        auto state(step->state.lock());
        for (auto & dep : state->deps)
            if (queued.find(dep) == queued.end()) {
                queued.insert(dep);
                todo.push(dep);
            }
    }
}


void State::markSucceededBuild(pqxx::work & txn, Build::ptr build,
    const BuildOutput & res, bool isCachedBuild, time_t startTime, time_t stopTime)
{
    if (build->finishedInDB) return;

    if (txn.exec_params("select 1 from Builds where id = $1 and finished = 0", build->id).empty()) return;

    txn.exec_params0
        ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $4, size = $5, closureSize = $6, releaseName = $7, isCachedBuild = $8, notificationPendingSince = $4 where id = $1",
         build->id,
         (int) (res.failed ? bsFailedWithOutput : bsSuccess),
         startTime,
         stopTime,
         res.size,
         res.closureSize,
         res.releaseName != "" ? std::make_optional(res.releaseName) : std::nullopt,
         isCachedBuild ? 1 : 0);

    txn.exec_params0("delete from BuildProducts where build = $1", build->id);

    unsigned int productNr = 1;
    for (auto & product : res.products) {
        txn.exec_params0
            ("insert into BuildProducts (build, productnr, type, subtype, fileSize, sha256hash, path, name, defaultPath) values ($1, $2, $3, $4, $5, $6, $7, $8, $9)",
             build->id,
             productNr++,
             product.type,
             product.subtype,
             product.fileSize ? std::make_optional(*product.fileSize) : std::nullopt,
             product.sha256hash ? std::make_optional(product.sha256hash->to_string(HashFormat::Base16, false)) : std::nullopt,
             product.path,
             product.name,
             product.defaultPath);
    }

    txn.exec_params0("delete from BuildMetrics where build = $1", build->id);

    for (auto & metric : res.metrics) {
        txn.exec_params0
            ("insert into BuildMetrics (build, name, unit, value, project, jobset, job, timestamp) values ($1, $2, $3, $4, $5, $6, $7, $8)",
             build->id,
             metric.second.name,
             metric.second.unit != "" ? std::make_optional(metric.second.unit) : std::nullopt,
             metric.second.value,
             build->projectName,
             build->jobsetName,
             build->jobName,
             build->timestamp);
    }

    nrBuildsDone++;
}


bool State::checkCachedFailure(Step::ptr step, Connection & conn)
{
    pqxx::work txn(conn);
    for (auto & i : step->drv->outputsAndOptPaths(*localStore))
        if (i.second.second)
            if (!txn.exec_params("select 1 from FailedPaths where path = $1", localStore->printStorePath(*i.second.second)).empty())
                return true;
    return false;
}


void State::notifyBuildStarted(pqxx::work & txn, BuildID buildId)
{
    txn.exec(fmt("notify build_started, '%s'", buildId));
}


void State::notifyBuildFinished(pqxx::work & txn, BuildID buildId,
    const std::vector<BuildID> & dependentIds)
{
    auto payload = fmt("%d", buildId);
    for (auto & d : dependentIds)
        payload += fmt("\t%d", d);
    // FIXME: apparently parameterized() doesn't support NOTIFY.
    txn.exec(fmt("notify build_finished, '%s'", payload));
}


std::shared_ptr<PathLocks> State::acquireGlobalLock()
{
    Path lockPath = hydraData + "/queue-runner/lock";

    createDirs(dirOf(lockPath));

    auto lock = std::make_shared<PathLocks>();
    if (!lock->lockPaths(PathSet({lockPath}), "", false)) return 0;

    return lock;
}


void State::dumpStatus(Connection & conn)
{
    time_t now = time(0);
    json statusJson = {
        {"status", "up"},
        {"time", time(0)},
        {"uptime", now - startedAt},
        {"pid", getpid()},

        {"nrQueuedBuilds", builds.lock()->size()},
        {"nrActiveSteps", activeSteps_.lock()->size()},
        {"nrStepsBuilding", nrStepsBuilding.load()},
        {"nrStepsCopyingTo", nrStepsCopyingTo.load()},
        {"nrStepsCopyingFrom", nrStepsCopyingFrom.load()},
        {"nrStepsWaiting", nrStepsWaiting.load()},
        {"nrUnsupportedSteps", nrUnsupportedSteps.load()},
        {"bytesSent", bytesSent.load()},
        {"bytesReceived", bytesReceived.load()},
        {"nrBuildsRead", nrBuildsRead.load()},
        {"buildReadTimeMs", buildReadTimeMs.load()},
        {"buildReadTimeAvgMs", nrBuildsRead == 0 ? 0.0 : (float) buildReadTimeMs / nrBuildsRead},
        {"nrBuildsDone", nrBuildsDone.load()},
        {"nrStepsStarted", nrStepsStarted.load()},
        {"nrStepsDone", nrStepsDone.load()},
        {"nrRetries", nrRetries.load()},
        {"maxNrRetries", maxNrRetries.load()},
        {"nrQueueWakeups", nrQueueWakeups.load()},
        {"nrDispatcherWakeups", nrDispatcherWakeups.load()},
        {"dispatchTimeMs", dispatchTimeMs.load()},
        {"dispatchTimeAvgMs", nrDispatcherWakeups == 0 ? 0.0 : (float) dispatchTimeMs / nrDispatcherWakeups},
        {"nrDbConnections", dbPool.count()},
        {"nrActiveDbUpdates", nrActiveDbUpdates.load()},
    };
    {
        {
            auto steps_(steps.lock());
            for (auto i = steps_->begin(); i != steps_->end(); )
                if (i->second.lock()) ++i; else i = steps_->erase(i);
            statusJson["nrUnfinishedSteps"] = steps_->size();
        }
        {
            auto runnable_(runnable.lock());
            for (auto i = runnable_->begin(); i != runnable_->end(); )
                if (i->lock()) ++i; else i = runnable_->erase(i);
            statusJson["nrRunnableSteps"] = runnable_->size();
        }
        if (nrStepsDone) {
            statusJson["totalStepTime"] = totalStepTime.load();
            statusJson["totalStepBuildTime"] = totalStepBuildTime.load();
            statusJson["avgStepTime"] = (float) totalStepTime / nrStepsDone;
            statusJson["avgStepBuildTime"] = (float) totalStepBuildTime / nrStepsDone;
        }

        {
            auto machines_(machines.lock());
            for (auto & i : *machines_) {
                auto & m(i.second);
                auto & s(m->state);
                auto info(m->state->connectInfo.lock());

                json machine = {
                    {"enabled",  m->enabled},
                    {"systemTypes", m->systemTypes},
                    {"supportedFeatures", m->supportedFeatures},
                    {"mandatoryFeatures", m->mandatoryFeatures},
                    {"nrStepsDone", s->nrStepsDone.load()},
                    {"currentJobs", s->currentJobs.load()},
                    {"disabledUntil", std::chrono::system_clock::to_time_t(info->disabledUntil)},
                    {"lastFailure", std::chrono::system_clock::to_time_t(info->lastFailure)},
                    {"consecutiveFailures", info->consecutiveFailures},
                };

                if (s->currentJobs == 0)
                    machine["idleSince"] = s->idleSince.load();
                if (m->state->nrStepsDone) {
                    machine["totalStepTime"] = s->totalStepTime.load();
                    machine["totalStepBuildTime"] = s->totalStepBuildTime.load();
                    machine["avgStepTime"] = (float) s->totalStepTime / s->nrStepsDone;
                    machine["avgStepBuildTime"] = (float) s->totalStepBuildTime / s->nrStepsDone;
                }
                statusJson["machines"][m->sshName] = machine;
            }
        }

        {
            auto jobsets_json = json::object();
            auto jobsets_(jobsets.lock());
            for (auto & jobset : *jobsets_) {
                jobsets_json[jobset.first.first + ":" + jobset.first.second] = {
                    {"shareUsed", jobset.second->shareUsed()},
                    {"seconds", jobset.second->getSeconds()},
                };
            }
            statusJson["jobsets"] = jobsets_json;
        }

        {
            auto machineTypesJson = json::object();
            auto machineTypes_(machineTypes.lock());
            for (auto & i : *machineTypes_) {
                auto machineTypeJson = machineTypesJson[i.first] = {
                    {"runnable", i.second.runnable},
                    {"running", i.second.running},
                };
                if (i.second.runnable > 0)
                    machineTypeJson["waitTime"] = i.second.waitTime.count() +
                        i.second.runnable * (time(0) - lastDispatcherCheck);
                if (i.second.running == 0)
                    machineTypeJson["lastActive"] = std::chrono::system_clock::to_time_t(i.second.lastActive);
            }
            statusJson["machineTypes"] = machineTypesJson;
        }

        auto store = getDestStore();

        auto & stats = store->getStats();
        statusJson["store"] = {
            {"narInfoRead", stats.narInfoRead.load()},
            {"narInfoReadAverted", stats.narInfoReadAverted.load()},
            {"narInfoMissing", stats.narInfoMissing.load()},
            {"narInfoWrite", stats.narInfoWrite.load()},
            {"narInfoCacheSize", stats.pathInfoCacheSize.load()},
            {"narRead", stats.narRead.load()},
            {"narReadBytes", stats.narReadBytes.load()},
            {"narReadCompressedBytes", stats.narReadCompressedBytes.load()},
            {"narWrite", stats.narWrite.load()},
            {"narWriteAverted", stats.narWriteAverted.load()},
            {"narWriteBytes", stats.narWriteBytes.load()},
            {"narWriteCompressedBytes", stats.narWriteCompressedBytes.load()},
            {"narWriteCompressionTimeMs", stats.narWriteCompressionTimeMs.load()},
            {"narCompressionSavings",
             stats.narWriteBytes
             ? 1.0 - (double) stats.narWriteCompressedBytes / stats.narWriteBytes
             : 0.0},
            {"narCompressionSpeed", // MiB/s
            stats.narWriteCompressionTimeMs
            ? (double) stats.narWriteBytes / stats.narWriteCompressionTimeMs * 1000.0 / (1024.0 * 1024.0)
            : 0.0},
        };

        auto s3Store = dynamic_cast<S3BinaryCacheStore *>(&*store);
        if (s3Store) {
            auto & s3Stats = s3Store->getS3Stats();
            auto jsonS3 = statusJson["s3"] = {
                {"put", s3Stats.put.load()},
                {"putBytes", s3Stats.putBytes.load()},
                {"putTimeMs", s3Stats.putTimeMs.load()},
                {"putSpeed",
                 s3Stats.putTimeMs
                 ? (double) s3Stats.putBytes / s3Stats.putTimeMs * 1000.0 / (1024.0 * 1024.0)
                 : 0.0},
                {"get", s3Stats.get.load()},
                {"getBytes", s3Stats.getBytes.load()},
                {"getTimeMs", s3Stats.getTimeMs.load()},
                {"getSpeed",
                 s3Stats.getTimeMs
                 ? (double) s3Stats.getBytes / s3Stats.getTimeMs * 1000.0 / (1024.0 * 1024.0)
                 : 0.0},
                {"head", s3Stats.head.load()},
                {"costDollarApprox",
                        (s3Stats.get + s3Stats.head) / 10000.0 * 0.004
                        + s3Stats.put / 1000.0 * 0.005 +
                        + s3Stats.getBytes / (1024.0 * 1024.0 * 1024.0) * 0.09},
            };
        }
    }

    {
        auto mc = startDbUpdate();
        pqxx::work txn(conn);
        // FIXME: use PostgreSQL 9.5 upsert.
        txn.exec("delete from SystemStatus where what = 'queue-runner'");
        txn.exec_params0("insert into SystemStatus values ('queue-runner', $1)", statusJson.dump());
        txn.exec("notify status_dumped");
        txn.commit();
    }
}


void State::showStatus()
{
    auto conn(dbPool.get());
    receiver statusDumped(*conn, "status_dumped");

    std::string status;
    bool barf = false;

    /* Get the last JSON status dump from the database. */
    {
        pqxx::work txn(*conn);
        auto res = txn.exec("select status from SystemStatus where what = 'queue-runner'");
        if (res.size()) status = res[0][0].as<std::string>();
    }

    if (status != "") {

        /* If the status is not empty, then the queue runner is
           running. Ask it to update the status dump. */
        {
            pqxx::work txn(*conn);
            txn.exec("notify dump_status");
            txn.commit();
        }

        /* Wait until it has done so. */
        barf = conn->await_notification(5, 0) == 0;

        /* Get the new status. */
        {
            pqxx::work txn(*conn);
            auto res = txn.exec("select status from SystemStatus where what = 'queue-runner'");
            if (res.size()) status = res[0][0].as<std::string>();
        }

    }

    if (status == "") status = R"({"status":"down"})";

    std::cout << status << "\n";

    if (barf)
        throw Error("queue runner did not respond; status information may be wrong");
}


void State::unlock()
{
    auto lock = acquireGlobalLock();
    if (!lock)
        throw Error("hydra-queue-runner is currently running");

    auto conn(dbPool.get());

    clearBusy(*conn, 0);

    {
        pqxx::work txn(*conn);
        txn.exec("delete from SystemStatus where what = 'queue-runner'");
        txn.commit();
    }
}


void State::run(BuildID buildOne)
{
    /* Can't be bothered to shut down cleanly. Goodbye! */
    auto callback = createInterruptCallback([&]() { std::_Exit(0); });

    startedAt = time(0);
    this->buildOne = buildOne;

    auto lock = acquireGlobalLock();
    if (!lock)
        throw Error("hydra-queue-runner is already running");

    std::cout << "Starting the Prometheus exporter on " << metricsAddr << std::endl;

    /* Set up simple exporter, to show that we're still alive. */
    prometheus::Exposer promExposer{metricsAddr};
    auto exposerPort = promExposer.GetListeningPorts().front();

    promExposer.RegisterCollectable(prom.registry);

    std::cout << "Started the Prometheus exporter, listening on "
        << metricsAddr << "/metrics (port " << exposerPort << ")"
        << std::endl;

    Store::Params localParams;
    localParams["max-connections"] = "16";
    localParams["max-connection-age"] = "600";
    localStore = openStore(getEnv("NIX_REMOTE").value_or(""), localParams);

    auto storeUri = config->getStrOption("store_uri");
    _destStore = storeUri == "" ? localStore : openStore(storeUri);

    useSubstitutes = config->getBoolOption("use-substitutes", false);

    // FIXME: hacky mechanism for configuring determinism checks.
    for (auto & s : tokenizeString<Strings>(config->getStrOption("xxx-jobset-repeats"))) {
        auto s2 = tokenizeString<std::vector<std::string>>(s, ":");
        if (s2.size() != 3) throw Error("bad value in xxx-jobset-repeats");
        jobsetRepeats.emplace(std::make_pair(s2[0], s2[1]), std::stoi(s2[2]));
    }

    {
        auto conn(dbPool.get());
        clearBusy(*conn, 0);
        dumpStatus(*conn);
    }

    machinesReadyLock.lock();
    std::thread(&State::monitorMachinesFile, this).detach();

    std::thread(&State::queueMonitor, this).detach();

    std::thread(&State::dispatcher, this).detach();

    /* Periodically clean up orphaned busy steps in the database. */
    std::thread([&]() {
        while (true) {
            sleep(180);

            std::set<std::pair<BuildID, int>> steps;
            {
                auto orphanedSteps_(orphanedSteps.lock());
                if (orphanedSteps_->empty()) continue;
                steps = *orphanedSteps_;
                orphanedSteps_->clear();
            }

            try {
                auto conn(dbPool.get());
                pqxx::work txn(*conn);
                for (auto & step : steps) {
                    printMsg(lvlError, "cleaning orphaned step %d of build %d", step.second, step.first);
                    txn.exec_params0
                        ("update BuildSteps set busy = 0, status = $1 where build = $2 and stepnr = $3 and busy != 0",
                         (int) bsAborted,
                         step.first,
                         step.second);
                }
                txn.commit();
            } catch (std::exception & e) {
                printMsg(lvlError, "cleanup thread: %s", e.what());
                auto orphanedSteps_(orphanedSteps.lock());
                orphanedSteps_->insert(steps.begin(), steps.end());
            }
        }
    }).detach();

    /* Make sure that old daemon connections are closed even when
       we're not doing much. */
    std::thread([&]() {
        while (true) {
            sleep(10);
            try {
                if (auto remoteStore = getDestStore().dynamic_pointer_cast<RemoteStore>())
                    remoteStore->flushBadConnections();
            } catch (std::exception & e) {
                printMsg(lvlError, "connection flush thread: %s", e.what());
            }
        }
    }).detach();

    /* Monitor the database for status dump requests (e.g. from
       ‘hydra-queue-runner --status’). */
    while (true) {
        try {
            auto conn(dbPool.get());
            receiver dumpStatus_(*conn, "dump_status");
            while (true) {
                conn->await_notification();
                dumpStatus(*conn);
            }
        } catch (std::exception & e) {
            printMsg(lvlError, "main thread: %s", e.what());
            sleep(10); // probably a DB problem, so don't retry right away
        }
    }
}


int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();

        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);

        // FIXME: do this in the child environment in openConnection().
        unsetenv("IN_SYSTEMD");

        bool unlock = false;
        bool status = false;
        BuildID buildOne = 0;
        std::optional<std::string> metricsAddrOpt = std::nullopt;

        parseCmdLine(argc, argv, [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--unlock")
                unlock = true;
            else if (*arg == "--status")
                status = true;
            else if (*arg == "--build-one") {
                if (auto b = string2Int<BuildID>(getArg(*arg, arg, end)))
                    buildOne = *b;
                else
                    throw Error("‘--build-one’ requires a build ID");
            } else if (*arg == "--prometheus-address") {
                metricsAddrOpt = getArg(*arg, arg, end);
            } else
                return false;
            return true;
        });

        settings.verboseBuild = true;

        State state{metricsAddrOpt};
        if (status)
            state.showStatus();
        else if (unlock)
            state.unlock();
        else
            state.run(buildOne);
    });
}

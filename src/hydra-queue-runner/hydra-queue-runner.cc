#include <iostream>
#include <thread>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "state.hh"
#include "build-result.hh"
#include "local-binary-cache-store.hh"
#include "s3-binary-cache-store.hh"

#include "shared.hh"
#include "globals.hh"
#include "value-to-json.hh"

using namespace nix;


State::State()
{
    hydraData = getEnv("HYDRA_DATA");
    if (hydraData == "") throw Error("$HYDRA_DATA must be set");

    logDir = canonPath(hydraData + "/build-logs");
}


ref<Store> State::getLocalStore()
{
    return openStore(); // FIXME: pool
}


ref<Store> State::getDestStore()
{
#if 0
    auto store = make_ref<LocalBinaryCacheStore>(getLocalStore(),
        "/home/eelco/Misc/Keys/test.nixos.org/secret",
        "/home/eelco/Misc/Keys/test.nixos.org/public",
        "/tmp/binary-cache");
#endif
    auto store = make_ref<S3BinaryCacheStore>(getLocalStore(),
        "/home/eelco/Misc/Keys/test.nixos.org/secret",
        "/home/eelco/Misc/Keys/test.nixos.org/public",
        "nix-test-cache-3");
    store->init();
    return store;
}


void State::parseMachines(const std::string & contents)
{
    Machines newMachines, oldMachines;
    {
        auto machines_(machines.lock());
        oldMachines = *machines_;
    }

    for (auto line : tokenizeString<Strings>(contents, "\n")) {
        line = trim(string(line, 0, line.find('#')));
        auto tokens = tokenizeString<std::vector<std::string>>(line);
        if (tokens.size() < 3) continue;
        tokens.resize(8);

        auto machine = std::make_shared<Machine>();
        machine->sshName = tokens[0];
        machine->systemTypes = tokenizeString<StringSet>(tokens[1], ",");
        machine->sshKey = tokens[2] == "-" ? string("") : tokens[2];
        if (tokens[3] != "")
            string2Int(tokens[3], machine->maxJobs);
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
            printMsg(lvlChatty, format("adding new machine ‘%1%’") % machine->sshName);
        else
            printMsg(lvlChatty, format("updating machine ‘%1%’") % machine->sshName);
        machine->state = i == oldMachines.end()
            ? std::make_shared<Machine::State>()
            : i->second->state;
        newMachines[machine->sshName] = machine;
    }

    for (auto & m : oldMachines)
        if (newMachines.find(m.first) == newMachines.end()) {
            if (m.second->enabled)
                printMsg(lvlInfo, format("removing machine ‘%1%’") % m.first);
            /* Add a disabled Machine object to make sure stats are
               maintained. */
            auto machine = std::make_shared<Machine>(*(m.second));
            machine->enabled = false;
            newMachines[m.first] = machine;
        }

    auto machines_(machines.lock());
    *machines_ = newMachines;

    wakeDispatcher();
}


void State::monitorMachinesFile()
{
    string defaultMachinesFile = "/etc/nix/machines";
    auto machinesFiles = tokenizeString<std::vector<Path>>(
        getEnv("NIX_REMOTE_SYSTEMS", pathExists(defaultMachinesFile) ? defaultMachinesFile : ""), ":");

    if (machinesFiles.empty()) {
        parseMachines("localhost " +
            (settings.thisSystem == "x86_64-linux" ? "x86_64-linux,i686-linux" : settings.thisSystem)
            + " - " + std::to_string(settings.maxBuildJobs) + " 1");
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
                    throw SysError(format("getting stats about ‘%1%’") % machinesFile);
                st.st_ino = st.st_mtime = 0;
            }
            auto & old(fileStats[n]);
            if (old.st_ino != st.st_ino || old.st_mtime != st.st_mtime)
                anyChanged = true;
            old = st;
        }

        if (!anyChanged) return;

        debug("reloading machines files");

        string contents;
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

    while (true) {
        try {
            readMachinesFiles();
            // FIXME: use inotify.
            sleep(30);
        } catch (std::exception & e) {
            printMsg(lvlError, format("reloading machines file: %1%") % e.what());
        }
    }
}


void State::clearBusy(Connection & conn, time_t stopTime)
{
    pqxx::work txn(conn);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, stopTime = $2 where busy = 1")
        ((int) bssAborted)
        (stopTime, stopTime != 0).exec();
    txn.commit();
}


int State::allocBuildStep(pqxx::work & txn, Build::ptr build)
{
    /* Acquire an exclusive lock on BuildSteps to ensure that we don't
       race with other threads creating a step of the same build. */
    txn.exec("lock table BuildSteps in exclusive mode");

    auto res = txn.parameterized("select max(stepnr) from BuildSteps where build = $1")(build->id).exec();
    return res[0][0].is_null() ? 1 : res[0][0].as<int>() + 1;
}


int State::createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
    const std::string & machine, BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    int stepNr = allocBuildStep(txn, build);

    txn.parameterized
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, startTime, system, status, propagatedFrom, errorMsg, stopTime, machine) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)")
        (build->id)
        (stepNr)
        (0) // == build
        (step->drvPath)
        (status == bssBusy ? 1 : 0)
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


void State::finishBuildStep(pqxx::work & txn, time_t startTime, time_t stopTime, unsigned int overhead,
    BuildID buildId, int stepNr, const std::string & machine, BuildStepStatus status,
    const std::string & errorMsg, BuildID propagatedFrom)
{
    assert(startTime);
    assert(stopTime);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, propagatedFrom = $4, errorMsg = $5, startTime = $6, stopTime = $7, machine = $8, overhead = $9 where build = $2 and stepnr = $3")
        ((int) status)(buildId)(stepNr)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (startTime)(stopTime)
        (machine, machine != "")
        (overhead, overhead != 0).exec();
}


int State::createSubstitutionStep(pqxx::work & txn, time_t startTime, time_t stopTime,
    Build::ptr build, const Path & drvPath, const string & outputName, const Path & storePath)
{
    int stepNr = allocBuildStep(txn, build);

    txn.parameterized
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, status, startTime, stopTime) values ($1, $2, $3, $4, $5, $6, $7, $8)")
        (build->id)
        (stepNr)
        (1) // == substitution
        (drvPath)
        (0)
        (0)
        (startTime)
        (stopTime).exec();

    txn.parameterized
        ("insert into BuildStepOutputs (build, stepnr, name, path) values ($1, $2, $3, $4)")
        (build->id)(stepNr)(outputName)(storePath).exec();

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
    printMsg(lvlInfo, format("marking build %1% as succeeded") % build->id);

    if (build->finishedInDB) return;

    if (txn.parameterized("select 1 from Builds where id = $1 and finished = 0")(build->id).exec().empty()) return;

    txn.parameterized
        ("update Builds set finished = 1, buildStatus = $2, startTime = $3, stopTime = $4, size = $5, closureSize = $6, releaseName = $7, isCachedBuild = $8 where id = $1")
        (build->id)
        ((int) (res.failed ? bsFailedWithOutput : bsSuccess))
        (startTime)
        (stopTime)
        (res.size)
        (res.closureSize)
        (res.releaseName, res.releaseName != "")
        (isCachedBuild ? 1 : 0).exec();

    txn.parameterized("delete from BuildProducts where build = $1")(build->id).exec();

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

    txn.parameterized("delete from BuildMetrics where build = $1")(build->id).exec();

    for (auto & metric : res.metrics) {
        txn.parameterized
            ("insert into BuildMetrics (build, name, unit, value, project, jobset, job, timestamp) values ($1, $2, $3, $4, $5, $6, $7, $8)")
            (build->id)
            (metric.second.name)
            (metric.second.unit, metric.second.unit != "")
            (metric.second.value)
            (build->projectName)
            (build->jobsetName)
            (build->jobName)
            (build->timestamp).exec();
    }

    nrBuildsDone++;
}


bool State::checkCachedFailure(Step::ptr step, Connection & conn)
{
    pqxx::work txn(conn);
    for (auto & path : step->drv.outputPaths())
        if (!txn.parameterized("select 1 from FailedPaths where path = $1")(path).exec().empty())
            return true;
    return false;
}


void State::logCompressor()
{
    while (true) {
        try {

            Path logPath;
            {
                auto logCompressorQueue_(logCompressorQueue.lock());
                while (logCompressorQueue_->empty())
                    logCompressorQueue_.wait(logCompressorWakeup);
                logPath = logCompressorQueue_->front();
                logCompressorQueue_->pop();
            }

            if (!pathExists(logPath)) continue;

            printMsg(lvlChatty, format("compressing log file ‘%1%’") % logPath);

            Path tmpPath = logPath + ".bz2.tmp";

            AutoCloseFD fd = open(tmpPath.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0644);

            // FIXME: use libbz2

            Pid pid = startProcess([&]() {
                if (dup2(fd, STDOUT_FILENO) == -1)
                    throw SysError("cannot dup output pipe to stdout");
                execlp("bzip2", "bzip2", "-c", logPath.c_str(), nullptr);
                throw SysError("cannot start bzip2");
            });

            int res = pid.wait(true);

            if (res != 0)
                throw Error(format("bzip2 returned exit code %1% while compressing ‘%2%’")
                    % res % logPath);

            if (rename(tmpPath.c_str(), (logPath + ".bz2").c_str()) != 0)
                throw SysError(format("renaming ‘%1%’") % tmpPath);

            if (unlink(logPath.c_str()) != 0)
                throw SysError(format("unlinking ‘%1%’") % logPath);

        } catch (std::exception & e) {
            printMsg(lvlError, format("log compressor: %1%") % e.what());
            sleep(5);
        }
    }
}


void State::notificationSender()
{
    while (true) {
        try {

            NotificationItem item;
            {
                auto notificationSenderQueue_(notificationSenderQueue.lock());
                while (notificationSenderQueue_->empty())
                    notificationSenderQueue_.wait(notificationSenderWakeup);
                item = notificationSenderQueue_->front();
                notificationSenderQueue_->pop();
            }

            printMsg(lvlChatty, format("sending notification about build %1%") % item.first);

            Pid pid = startProcess([&]() {
                Strings argv({"hydra-notify", "build", std::to_string(item.first)});
                for (auto id : item.second)
                    argv.push_back(std::to_string(id));
                execvp("hydra-notify", (char * *) stringsToCharPtrs(argv).data()); // FIXME: remove cast
                throw SysError("cannot start hydra-notify");
            });

            int res = pid.wait(true);

            if (res != 0)
                throw Error(format("hydra-build returned exit code %1% notifying about build %2%")
                    % res % item.first);

        } catch (std::exception & e) {
            printMsg(lvlError, format("notification sender: %1%") % e.what());
            sleep(5);
        }
    }
}


std::shared_ptr<PathLocks> State::acquireGlobalLock()
{
    Path lockPath = hydraData + "/queue-runner/lock";

    createDirs(dirOf(lockPath));

    auto lock = std::make_shared<PathLocks>();
    if (!lock->lockPaths(PathSet({lockPath}), "", false)) return 0;

    return lock;
}


void State::dumpStatus(Connection & conn, bool log)
{
    std::ostringstream out;

    {
        JSONObject root(out);
        time_t now = time(0);
        root.attr("status", "up");
        root.attr("time", time(0));
        root.attr("uptime", now - startedAt);
        root.attr("pid", getpid());
        {
            auto builds_(builds.lock());
            root.attr("nrQueuedBuilds", builds_->size());
        }
        {
            auto steps_(steps.lock());
            for (auto i = steps_->begin(); i != steps_->end(); )
                if (i->second.lock()) ++i; else i = steps_->erase(i);
            root.attr("nrUnfinishedSteps", steps_->size());
        }
        {
            auto runnable_(runnable.lock());
            for (auto i = runnable_->begin(); i != runnable_->end(); )
                if (i->lock()) ++i; else i = runnable_->erase(i);
            root.attr("nrRunnableSteps", runnable_->size());
        }
        root.attr("nrActiveSteps", nrActiveSteps);
        root.attr("nrStepsBuilding", nrStepsBuilding);
        root.attr("nrStepsCopyingTo", nrStepsCopyingTo);
        root.attr("nrStepsCopyingFrom", nrStepsCopyingFrom);
        root.attr("nrStepsWaiting", nrStepsWaiting);
        root.attr("bytesSent"); out << bytesSent;
        root.attr("bytesReceived"); out << bytesReceived;
        root.attr("nrBuildsRead", nrBuildsRead);
        root.attr("nrBuildsDone", nrBuildsDone);
        root.attr("nrStepsDone", nrStepsDone);
        root.attr("nrRetries", nrRetries);
        root.attr("maxNrRetries", maxNrRetries);
        if (nrStepsDone) {
            root.attr("totalStepTime", totalStepTime);
            root.attr("totalStepBuildTime", totalStepBuildTime);
            root.attr("avgStepTime"); out << (float) totalStepTime / nrStepsDone;
            root.attr("avgStepBuildTime"); out << (float) totalStepBuildTime / nrStepsDone;
        }
        root.attr("nrQueueWakeups", nrQueueWakeups);
        root.attr("nrDispatcherWakeups", nrDispatcherWakeups);
        root.attr("nrDbConnections", dbPool.count());
        {
            root.attr("machines");
            JSONObject nested(out);
            auto machines_(machines.lock());
            for (auto & i : *machines_) {
                auto & m(i.second);
                auto & s(m->state);
                nested.attr(m->sshName);
                JSONObject nested2(out);
                nested2.attr("enabled", m->enabled);
                nested2.attr("currentJobs", s->currentJobs);
                if (s->currentJobs == 0)
                    nested2.attr("idleSince", s->idleSince);
                nested2.attr("nrStepsDone", s->nrStepsDone);
                if (m->state->nrStepsDone) {
                    nested2.attr("totalStepTime", s->totalStepTime);
                    nested2.attr("totalStepBuildTime", s->totalStepBuildTime);
                    nested2.attr("avgStepTime"); out << (float) s->totalStepTime / s->nrStepsDone;
                    nested2.attr("avgStepBuildTime"); out << (float) s->totalStepBuildTime / s->nrStepsDone;
                }
            }
        }
        {
            root.attr("jobsets");
            JSONObject nested(out);
            auto jobsets_(jobsets.lock());
            for (auto & jobset : *jobsets_) {
                nested.attr(jobset.first.first + ":" + jobset.first.second);
                JSONObject nested2(out);
                nested2.attr("shareUsed"); out << jobset.second->shareUsed();
                nested2.attr("seconds", jobset.second->getSeconds());
            }
        }
        {
            root.attr("machineTypes");
            JSONObject nested(out);
            auto machineTypes_(machineTypes.lock());
            for (auto & i : *machineTypes_) {
                nested.attr(i.first);
                JSONObject nested2(out);
                nested2.attr("runnable", i.second.runnable);
                nested2.attr("running", i.second.running);
                if (i.second.runnable > 0)
                    nested2.attr("waitTime", i.second.waitTime.count() +
                        i.second.runnable * (time(0) - lastDispatcherCheck));
                if (i.second.running == 0)
                    nested2.attr("lastActive", std::chrono::system_clock::to_time_t(i.second.lastActive));
            }
        }
    }

    if (log) printMsg(lvlInfo, format("status: %1%") % out.str());

    {
        pqxx::work txn(conn);
        // FIXME: use PostgreSQL 9.5 upsert.
        txn.exec("delete from SystemStatus where what = 'queue-runner'");
        txn.parameterized("insert into SystemStatus values ('queue-runner', $1)")(out.str()).exec();
        txn.exec("notify status_dumped");
        txn.commit();
    }
}


void State::showStatus()
{
    auto conn(dbPool.get());
    receiver statusDumped(*conn, "status_dumped");

    string status;
    bool barf = false;

    /* Get the last JSON status dump from the database. */
    {
        pqxx::work txn(*conn);
        auto res = txn.exec("select status from SystemStatus where what = 'queue-runner'");
        if (res.size()) status = res[0][0].as<string>();
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
            if (res.size()) status = res[0][0].as<string>();
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
    startedAt = time(0);
    this->buildOne = buildOne;

    auto lock = acquireGlobalLock();
    if (!lock)
        throw Error("hydra-queue-runner is already running");

    {
        auto conn(dbPool.get());
        clearBusy(*conn, 0);
        dumpStatus(*conn, false);
    }

    std::thread(&State::monitorMachinesFile, this).detach();

    std::thread(&State::queueMonitor, this).detach();

    std::thread(&State::dispatcher, this).detach();

    /* Run a log compressor thread. If needed, we could start more
       than one. */
    std::thread(&State::logCompressor, this).detach();

    /* Idem for notification sending. */
    std::thread(&State::notificationSender, this).detach();

    /* Monitor the database for status dump requests (e.g. from
       ‘hydra-queue-runner --status’). */
    while (true) {
        try {
            auto conn(dbPool.get());
            receiver dumpStatus_(*conn, "dump_status");
            while (true) {
                bool timeout = conn->await_notification(300, 0) == 0;
                dumpStatus(*conn, timeout);
            }
        } catch (std::exception & e) {
            printMsg(lvlError, format("main thread: %1%") % e.what());
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

        bool unlock = false;
        bool status = false;
        BuildID buildOne = 0;

        parseCmdLine(argc, argv, [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--unlock")
                unlock = true;
            else if (*arg == "--status")
                status = true;
            else if (*arg == "--build-one") {
                if (!string2Int<BuildID>(getArg(*arg, arg, end), buildOne))
                    throw Error("‘--build-one’ requires a build ID");
            } else
                return false;
            return true;
        });

        settings.buildVerbosity = lvlVomit;
        settings.lockCPU = false;

        State state;
        if (status)
            state.showStatus();
        else if (unlock)
            state.unlock();
        else
            state.run(buildOne);
    });
}

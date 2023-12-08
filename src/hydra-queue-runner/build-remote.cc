#include <algorithm>
#include <cmath>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "build-result.hh"
#include "path.hh"
#include "serve-protocol.hh"
#include "state.hh"
#include "current-process.hh"
#include "processes.hh"
#include "util.hh"
#include "serve-protocol.hh"
#include "serve-protocol-impl.hh"
#include "finally.hh"
#include "url.hh"

using namespace nix;


struct Child
{
    Pid pid;
    AutoCloseFD to, from;
};


static void append(Strings & dst, const Strings & src)
{
    dst.insert(dst.end(), src.begin(), src.end());
}

namespace nix::build_remote {

static Strings extraStoreArgs(std::string & machine)
{
    Strings result;
    try {
        auto parsed = parseURL(machine);
        if (parsed.scheme != "ssh") {
            throw SysError("Currently, only (legacy-)ssh stores are supported!");
        }
        machine = parsed.authority.value_or("");
        auto remoteStore = parsed.query.find("remote-store");
        if (remoteStore != parsed.query.end()) {
            result = {"--store", shellEscape(remoteStore->second)};
        }
    } catch (BadURL &) {
        // We just try to continue with `machine->sshName` here for backwards compat.
    }

    return result;
}

static void openConnection(Machine::ptr machine, Path tmpDir, int stderrFD, Child & child)
{
    std::string pgmName;
    Pipe to, from;
    to.create();
    from.create();

    Strings argv;
    if (machine->isLocalhost()) {
        pgmName = "nix-store";
        argv = {"nix-store", "--builders", "", "--serve", "--write"};
    } else {
        pgmName = "ssh";
        auto sshName = machine->sshName;
        Strings extraArgs = extraStoreArgs(sshName);
        argv = {"ssh", sshName};
        if (machine->sshKey != "") append(argv, {"-i", machine->sshKey});
        if (machine->sshPublicHostKey != "") {
            Path fileName = tmpDir + "/host-key";
            auto p = machine->sshName.find("@");
            std::string host = p != std::string::npos ? std::string(machine->sshName, p + 1) : machine->sshName;
            writeFile(fileName, host + " " + machine->sshPublicHostKey + "\n");
            append(argv, {"-oUserKnownHostsFile=" + fileName});
        }
        append(argv,
            { "-x", "-a", "-oBatchMode=yes", "-oConnectTimeout=60", "-oTCPKeepAlive=yes"
            , "--", "nix-store", "--serve", "--write" });
        append(argv, extraArgs);
    }

    child.pid = startProcess([&]() {
        restoreProcessContext();

        if (dup2(to.readSide.get(), STDIN_FILENO) == -1)
            throw SysError("cannot dup input pipe to stdin");

        if (dup2(from.writeSide.get(), STDOUT_FILENO) == -1)
            throw SysError("cannot dup output pipe to stdout");

        if (dup2(stderrFD, STDERR_FILENO) == -1)
            throw SysError("cannot dup stderr");

        execvp(argv.front().c_str(), (char * *) stringsToCharPtrs(argv).data()); // FIXME: remove cast

        throw SysError("cannot start %s", pgmName);
    });

    to.readSide = -1;
    from.writeSide = -1;

    child.to = to.writeSide.release();
    child.from = from.readSide.release();
}


static void copyClosureTo(
    Machine::Connection & conn,
    Store & destStore,
    const StorePathSet & paths,
    SubstituteFlag useSubstitutes = NoSubstitute)
{
    StorePathSet closure;
    destStore.computeFSClosure(paths, closure);

    /* Send the "query valid paths" command with the "lock" option
       enabled. This prevents a race where the remote host
       garbage-collect paths that are already there. Optionally, ask
       the remote host to substitute missing paths. */
    // FIXME: substitute output pollutes our build log
    conn.to << ServeProto::Command::QueryValidPaths << 1 << useSubstitutes;
    ServeProto::write(destStore, conn, closure);
    conn.to.flush();

    /* Get back the set of paths that are already valid on the remote
       host. */
    auto present = ServeProto::Serialise<StorePathSet>::read(destStore, conn);

    if (present.size() == closure.size()) return;

    auto sorted = destStore.topoSortPaths(closure);

    StorePathSet missing;
    for (auto i = sorted.rbegin(); i != sorted.rend(); ++i)
        if (!present.count(*i)) missing.insert(*i);

    printMsg(lvlDebug, "sending %d missing paths", missing.size());

    std::unique_lock<std::timed_mutex> sendLock(conn.machine->state->sendLock,
        std::chrono::seconds(600));

    conn.to << ServeProto::Command::ImportPaths;
    destStore.exportPaths(missing, conn.to);
    conn.to.flush();

    if (readInt(conn.from) != 1)
        throw Error("remote machine failed to import closure");
}


// FIXME: use Store::topoSortPaths().
static StorePaths reverseTopoSortPaths(const std::map<StorePath, ValidPathInfo> & paths)
{
    StorePaths sorted;
    StorePathSet visited;

    std::function<void(const StorePath & path)> dfsVisit;

    dfsVisit = [&](const StorePath & path) {
        if (!visited.insert(path).second) return;

        auto info = paths.find(path);
        auto references = info == paths.end() ? StorePathSet() : info->second.references;

        for (auto & i : references)
            /* Don't traverse into paths that don't exist.  That can
               happen due to substitutes for non-existent paths. */
            if (i != path && paths.count(i))
                dfsVisit(i);

        sorted.push_back(path);
    };

    for (auto & i : paths)
        dfsVisit(i.first);

    return sorted;
}

static std::pair<Path, AutoCloseFD> openLogFile(const std::string & logDir, const StorePath & drvPath)
{
    std::string base(drvPath.to_string());
    auto logFile = logDir + "/" + std::string(base, 0, 2) + "/" + std::string(base, 2);

    createDirs(dirOf(logFile));

    AutoCloseFD logFD = open(logFile.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0666);
    if (!logFD) throw SysError("creating log file ‘%s’", logFile);

    return {std::move(logFile), std::move(logFD)};
}

/**
 * @param conn is not fully initialized; it is this functions job to set
 * the `remoteVersion` field after the handshake is completed.
 * Therefore, no `ServeProto::Serialize` functions can be used until
 * that field is set.
 */
static void handshake(Machine::Connection & conn, unsigned int repeats)
{
    conn.to << SERVE_MAGIC_1 << 0x206;
    conn.to.flush();

    unsigned int magic = readInt(conn.from);
    if (magic != SERVE_MAGIC_2)
        throw Error("protocol mismatch with ‘nix-store --serve’ on ‘%1%’", conn.machine->sshName);
    conn.remoteVersion = readInt(conn.from);
    // Now `conn` is initialized.
    if (GET_PROTOCOL_MAJOR(conn.remoteVersion) != 0x200)
        throw Error("unsupported ‘nix-store --serve’ protocol version on ‘%1%’", conn.machine->sshName);
    if (GET_PROTOCOL_MINOR(conn.remoteVersion) < 3 && repeats > 0)
        throw Error("machine ‘%1%’ does not support repeating a build; please upgrade it to Nix 1.12", conn.machine->sshName);
}

static BasicDerivation sendInputs(
    State & state,
    Step & step,
    Store & localStore,
    Store & destStore,
    Machine::Connection & conn,
    unsigned int & overhead,
    counter & nrStepsWaiting,
    counter & nrStepsCopyingTo
)
{
    BasicDerivation basicDrv(*step.drv);

    for (const auto & [drvPath, node] : step.drv->inputDrvs.map) {
        auto drv2 = localStore.readDerivation(drvPath);
        for (auto & name : node.value) {
            if (auto i = get(drv2.outputs, name)) {
                auto outPath = i->path(localStore, drv2.name, name);
                basicDrv.inputSrcs.insert(*outPath);
            }
        }
    }

    /* Ensure that the inputs exist in the destination store. This is
       a no-op for regular stores, but for the binary cache store,
       this will copy the inputs to the binary cache from the local
       store. */
    if (&localStore != &destStore) {
        copyClosure(localStore, destStore,
            step.drv->inputSrcs,
            NoRepair, NoCheckSigs, NoSubstitute);
    }

    {
        auto mc1 = std::make_shared<MaintainCount<counter>>(nrStepsWaiting);
        mc1.reset();
        MaintainCount<counter> mc2(nrStepsCopyingTo);

        printMsg(lvlDebug, "sending closure of ‘%s’ to ‘%s’",
            localStore.printStorePath(step.drvPath), conn.machine->sshName);

        auto now1 = std::chrono::steady_clock::now();

        /* Copy the input closure. */
        if (conn.machine->isLocalhost()) {
            StorePathSet closure;
            destStore.computeFSClosure(basicDrv.inputSrcs, closure);
            copyPaths(destStore, localStore, closure, NoRepair, NoCheckSigs, NoSubstitute);
        } else {
            copyClosureTo(conn, destStore, basicDrv.inputSrcs, Substitute);
        }

        auto now2 = std::chrono::steady_clock::now();

        overhead += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();
    }

    return basicDrv;
}

static BuildResult performBuild(
    Machine::Connection & conn,
    Store & localStore,
    StorePath drvPath,
    const BasicDerivation & drv,
    const State::BuildOptions & options,
    counter & nrStepsBuilding
)
{
    conn.to << ServeProto::Command::BuildDerivation << localStore.printStorePath(drvPath);
    writeDerivation(conn.to, localStore, drv);
    conn.to << options.maxSilentTime << options.buildTimeout;
    if (GET_PROTOCOL_MINOR(conn.remoteVersion) >= 2)
        conn.to << options.maxLogSize;
    if (GET_PROTOCOL_MINOR(conn.remoteVersion) >= 3) {
        conn.to
            << options.repeats // == build-repeat
            << options.enforceDeterminism;
    }
    conn.to.flush();

    BuildResult result;

    time_t startTime, stopTime;

    startTime = time(0);
    {
        MaintainCount<counter> mc(nrStepsBuilding);
        result = ServeProto::Serialise<BuildResult>::read(localStore, conn);
    }
    stopTime = time(0);

    if (!result.startTime) {
        // If the builder gave `startTime = 0`, use our measurements
        // instead of the builder's.
        //
        // Note: this represents the duration of a single round, rather
        // than all rounds.
        result.startTime = startTime;
        result.stopTime = stopTime;
    }

    return result;
}

static std::map<StorePath, ValidPathInfo> queryPathInfos(
    Machine::Connection & conn,
    Store & localStore,
    StorePathSet & outputs,
    size_t & totalNarSize
)
{

    /* Get info about each output path. */
    std::map<StorePath, ValidPathInfo> infos;
    conn.to << ServeProto::Command::QueryPathInfos;
    ServeProto::write(localStore, conn, outputs);
    conn.to.flush();
    while (true) {
        auto storePathS = readString(conn.from);
        if (storePathS == "") break;
        auto deriver = readString(conn.from); // deriver
        auto references = ServeProto::Serialise<StorePathSet>::read(localStore, conn);
        readLongLong(conn.from); // download size
        auto narSize = readLongLong(conn.from);
        auto narHash = Hash::parseAny(readString(conn.from), htSHA256);
        auto ca = ContentAddress::parseOpt(readString(conn.from));
        readStrings<StringSet>(conn.from); // sigs
        ValidPathInfo info(localStore.parseStorePath(storePathS), narHash);
        assert(outputs.count(info.path));
        info.references = references;
        info.narSize = narSize;
        totalNarSize += info.narSize;
        info.narHash = narHash;
        info.ca = ca;
        if (deriver != "")
            info.deriver = localStore.parseStorePath(deriver);
        infos.insert_or_assign(info.path, info);
    }

    return infos;
}

static void copyPathFromRemote(
    Machine::Connection & conn,
    NarMemberDatas & narMembers,
    Store & localStore,
    Store & destStore,
    const ValidPathInfo & info
)
{
      /* Receive the NAR from the remote and add it to the
          destination store. Meanwhile, extract all the info from the
          NAR that getBuildOutput() needs. */
      auto source2 = sinkToSource([&](Sink & sink)
      {
          /* Note: we should only send the command to dump the store
              path to the remote if the NAR is actually going to get read
              by the destination store, which won't happen if this path
              is already valid on the destination store. Since this
              lambda function only gets executed if someone tries to read
              from source2, we will send the command from here rather
              than outside the lambda. */
          conn.to << ServeProto::Command::DumpStorePath << localStore.printStorePath(info.path);
          conn.to.flush();

          TeeSource tee(conn.from, sink);
          extractNarData(tee, localStore.printStorePath(info.path), narMembers);
      });

      destStore.addToStore(info, *source2, NoRepair, NoCheckSigs);
}

static void copyPathsFromRemote(
    Machine::Connection & conn,
    NarMemberDatas & narMembers,
    Store & localStore,
    Store & destStore,
    const std::map<StorePath, ValidPathInfo> & infos
)
{
      auto pathsSorted = reverseTopoSortPaths(infos);

      for (auto & path : pathsSorted) {
          auto & info = infos.find(path)->second;
          copyPathFromRemote(conn, narMembers, localStore, destStore, info);
      }

}

}

/* using namespace nix::build_remote; */

void RemoteResult::updateWithBuildResult(const nix::BuildResult & buildResult)
{
    startTime = buildResult.startTime;
    stopTime = buildResult.stopTime;
    timesBuilt = buildResult.timesBuilt;
    errorMsg = buildResult.errorMsg;
    isNonDeterministic = buildResult.isNonDeterministic;

    switch ((BuildResult::Status) buildResult.status) {
        case BuildResult::Built:
            stepStatus = bsSuccess;
            break;
        case BuildResult::Substituted:
        case BuildResult::AlreadyValid:
            stepStatus = bsSuccess;
            isCached = true;
            break;
        case BuildResult::PermanentFailure:
            stepStatus = bsFailed;
            canCache = true;
            errorMsg = "";
            break;
        case BuildResult::InputRejected:
        case BuildResult::OutputRejected:
            stepStatus = bsFailed;
            canCache = true;
            break;
        case BuildResult::TransientFailure:
            stepStatus = bsFailed;
            canRetry = true;
            errorMsg = "";
            break;
        case BuildResult::TimedOut:
            stepStatus = bsTimedOut;
            errorMsg = "";
            break;
        case BuildResult::MiscFailure:
            stepStatus = bsAborted;
            canRetry = true;
            break;
        case BuildResult::LogLimitExceeded:
            stepStatus = bsLogLimitExceeded;
            break;
        case BuildResult::NotDeterministic:
            stepStatus = bsNotDeterministic;
            canRetry = false;
            canCache = true;
            break;
        default:
            stepStatus = bsAborted;
            break;
    }

}


void State::buildRemote(ref<Store> destStore,
    Machine::ptr machine, Step::ptr step,
    const BuildOptions & buildOptions,
    RemoteResult & result, std::shared_ptr<ActiveStep> activeStep,
    std::function<void(StepState)> updateStep,
    NarMemberDatas & narMembers)
{
    assert(BuildResult::TimedOut == 8);

    auto [logFile, logFD] = build_remote::openLogFile(logDir, step->drvPath);
    AutoDelete logFileDel(logFile, false);
    result.logFile = logFile;

    nix::Path tmpDir = createTempDir();
    AutoDelete tmpDirDel(tmpDir, true);

    try {

        updateStep(ssConnecting);

        // FIXME: rewrite to use Store.
        Child child;
        build_remote::openConnection(machine, tmpDir, logFD.get(), child);

        {
            auto activeStepState(activeStep->state_.lock());
            if (activeStepState->cancelled) throw Error("step cancelled");
            activeStepState->pid = child.pid;
        }

        Finally clearPid([&]() {
            auto activeStepState(activeStep->state_.lock());
            activeStepState->pid = -1;

            /* FIXME: there is a slight race here with step
               cancellation in State::processQueueChange(), which
               could call kill() on this pid after we've done waitpid()
               on it. With pid wrap-around, there is a tiny
               possibility that we end up killing another
               process. Meh. */
        });

        Machine::Connection conn {
            .from = child.from.get(),
            .to = child.to.get(),
            .machine = machine,
        };

        Finally updateStats([&]() {
            bytesReceived += conn.from.read;
            bytesSent += conn.to.written;
        });

        try {
          build_remote::handshake(conn, buildOptions.repeats);
        } catch (EndOfFile & e) {
            child.pid.wait();
            std::string s = chomp(readFile(result.logFile));
            throw Error("cannot connect to ‘%1%’: %2%", machine->sshName, s);
        }

        {
            auto info(machine->state->connectInfo.lock());
            info->consecutiveFailures = 0;
        }

        /* Gather the inputs. If the remote side is Nix <= 1.9, we have to
           copy the entire closure of ‘drvPath’, as well as the required
           outputs of the input derivations. On Nix > 1.9, we only need to
           copy the immediate sources of the derivation and the required
           outputs of the input derivations. */
        updateStep(ssSendingInputs);
        BasicDerivation resolvedDrv = build_remote::sendInputs(*this, *step, *localStore, *destStore, conn, result.overhead, nrStepsWaiting, nrStepsCopyingTo);

        logFileDel.cancel();

        /* Truncate the log to get rid of messages about substitutions
            etc. on the remote system. */
        if (lseek(logFD.get(), SEEK_SET, 0) != 0)
            throw SysError("seeking to the start of log file ‘%s’", result.logFile);

        if (ftruncate(logFD.get(), 0) == -1)
            throw SysError("truncating log file ‘%s’", result.logFile);

        logFD = -1;

        /* Do the build. */
        printMsg(lvlDebug, "building ‘%s’ on ‘%s’",
            localStore->printStorePath(step->drvPath),
            machine->sshName);

        updateStep(ssBuilding);

        BuildResult buildResult = build_remote::performBuild(
            conn,
            *localStore,
            step->drvPath,
            resolvedDrv,
            buildOptions,
            nrStepsBuilding
        );

        result.updateWithBuildResult(buildResult);

        if (result.stepStatus != bsSuccess) return;

        result.errorMsg = "";

        /* If the path was substituted or already valid, then we didn't
           get a build log. */
        if (result.isCached) {
            printMsg(lvlInfo, "outputs of ‘%s’ substituted or already valid on ‘%s’",
                localStore->printStorePath(step->drvPath), machine->sshName);
            unlink(result.logFile.c_str());
            result.logFile = "";
        }

        /* Copy the output paths. */
        if (!machine->isLocalhost() || localStore != std::shared_ptr<Store>(destStore)) {
            updateStep(ssReceivingOutputs);

            MaintainCount<counter> mc(nrStepsCopyingFrom);

            auto now1 = std::chrono::steady_clock::now();

            StorePathSet outputs;
            for (auto & i : step->drv->outputsAndOptPaths(*localStore)) {
                if (i.second.second)
                   outputs.insert(*i.second.second);
            }

            size_t totalNarSize = 0;
            auto infos = build_remote::queryPathInfos(conn, *localStore, outputs, totalNarSize);

            if (totalNarSize > maxOutputSize) {
                result.stepStatus = bsNarSizeLimitExceeded;
                return;
            }

            /* Copy each path. */
            printMsg(lvlDebug, "copying outputs of ‘%s’ from ‘%s’ (%d bytes)",
                localStore->printStorePath(step->drvPath), machine->sshName, totalNarSize);

            build_remote::copyPathsFromRemote(conn, narMembers, *localStore, *destStore, infos);
            auto now2 = std::chrono::steady_clock::now();

            result.overhead += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();
        }

        /* Shut down the connection. */
        child.to = -1;
        child.pid.wait();

    } catch (Error & e) {
        /* Disable this machine until a certain period of time has
           passed. This period increases on every consecutive
           failure. However, don't count failures that occurred soon
           after the last one (to take into account steps started in
           parallel). */
        auto info(machine->state->connectInfo.lock());
        auto now = std::chrono::system_clock::now();
        if (info->consecutiveFailures == 0 || info->lastFailure < now - std::chrono::seconds(30)) {
            info->consecutiveFailures = std::min(info->consecutiveFailures + 1, (unsigned int) 4);
            info->lastFailure = now;
            int delta = retryInterval * std::pow(retryBackoff, info->consecutiveFailures - 1) + (rand() % 30);
            printMsg(lvlInfo, "will disable machine ‘%1%’ for %2%s", machine->sshName, delta);
            info->disabledUntil = now + std::chrono::seconds(delta);
        }
        throw;
    }
}

#include <algorithm>
#include <cmath>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "build-result.hh"
#include "path.hh"
#include "serve-protocol.hh"
#include "serve-protocol-impl.hh"
#include "state.hh"
#include "current-process.hh"
#include "processes.hh"
#include "util.hh"
#include "serve-protocol.hh"
#include "serve-protocol-impl.hh"
#include "ssh.hh"
#include "finally.hh"
#include "url.hh"

using namespace nix;

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

static std::unique_ptr<SSHMaster::Connection> openConnection(
    ::Machine::ptr machine, SSHMaster & master)
{
    Strings command = {"nix-store", "--serve", "--write"};
    if (machine->isLocalhost()) {
        command.push_back("--builders");
        command.push_back("");
    } else {
        command.splice(command.end(), extraStoreArgs(machine->sshName));
    }

    return master.startCommand(std::move(command), {
        "-a", "-oBatchMode=yes", "-oConnectTimeout=60", "-oTCPKeepAlive=yes"
    });
}


static void copyClosureTo(
    ::Machine::Connection & conn,
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
    /* Get back the set of paths that are already valid on the remote
       host. */
    auto present = conn.queryValidPaths(
        destStore, true, closure, useSubstitutes);

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
static StorePaths reverseTopoSortPaths(const std::map<StorePath, UnkeyedValidPathInfo> & paths)
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

static BasicDerivation sendInputs(
    State & state,
    Step & step,
    Store & localStore,
    Store & destStore,
    ::Machine::Connection & conn,
    unsigned int & overhead,
    counter & nrStepsWaiting,
    counter & nrStepsCopyingTo
)
{
    /* Replace the input derivations by their output paths to send a
       minimal closure to the builder.

       `tryResolve` currently does *not* rewrite input addresses, so it
       is safe to do this in all cases. (It should probably have a mode
       to do that, however, but we would not use it here.)
     */
    BasicDerivation basicDrv = ({
        auto maybeBasicDrv = step.drv->tryResolve(destStore, &localStore);
        if (!maybeBasicDrv)
            throw Error(
                "the derivation '%s' can’t be resolved. It’s probably "
                "missing some outputs",
                localStore.printStorePath(step.drvPath));
        *maybeBasicDrv;
    });

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
    ::Machine::Connection & conn,
    Store & localStore,
    StorePath drvPath,
    const BasicDerivation & drv,
    const ServeProto::BuildOptions & options,
    counter & nrStepsBuilding
)
{
    conn.putBuildDerivationRequest(localStore, drvPath, drv, options);

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

    // If the protocol was too old to give us `builtOutputs`, initialize
    // it manually by introspecting the derivation.
    if (GET_PROTOCOL_MINOR(conn.remoteVersion) < 6)
    {
        // If the remote is too old to handle CA derivations, we can’t get this
        // far anyways
        assert(drv.type().hasKnownOutputPaths());
        DerivationOutputsAndOptPaths drvOutputs = drv.outputsAndOptPaths(localStore);
        // Since this a `BasicDerivation`, `staticOutputHashes` will not
        // do any real work.
        auto outputHashes = staticOutputHashes(localStore, drv);
        for (auto & [outputName, output] : drvOutputs) {
            auto outputPath = output.second;
            // We’ve just asserted that the output paths of the derivation
            // were known
            assert(outputPath);
            auto outputHash = outputHashes.at(outputName);
            auto drvOutput = DrvOutput { outputHash, outputName };
            result.builtOutputs.insert_or_assign(
                std::move(outputName),
                Realisation { drvOutput, *outputPath });
        }
    }

    return result;
}

static std::map<StorePath, UnkeyedValidPathInfo> queryPathInfos(
    ::Machine::Connection & conn,
    Store & localStore,
    StorePathSet & outputs,
    size_t & totalNarSize
)
{

    /* Get info about each output path. */
    std::map<StorePath, UnkeyedValidPathInfo> infos;
    conn.to << ServeProto::Command::QueryPathInfos;
    ServeProto::write(localStore, conn, outputs);
    conn.to.flush();
    while (true) {
        auto storePathS = readString(conn.from);
        if (storePathS == "") break;

        auto storePath = localStore.parseStorePath(storePathS);
        auto info = ServeProto::Serialise<UnkeyedValidPathInfo>::read(localStore, conn);
        totalNarSize += info.narSize;
        infos.insert_or_assign(std::move(storePath), std::move(info));
    }

    return infos;
}

static void copyPathFromRemote(
    ::Machine::Connection & conn,
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
    ::Machine::Connection & conn,
    NarMemberDatas & narMembers,
    Store & localStore,
    Store & destStore,
    const std::map<StorePath, UnkeyedValidPathInfo> & infos
)
{
      auto pathsSorted = reverseTopoSortPaths(infos);

      for (auto & path : pathsSorted) {
          auto & info = infos.find(path)->second;
          copyPathFromRemote(
              conn, narMembers, localStore, destStore,
              ValidPathInfo { path, info });
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
    ::Machine::ptr machine, Step::ptr step,
    const ServeProto::BuildOptions & buildOptions,
    RemoteResult & result, std::shared_ptr<ActiveStep> activeStep,
    std::function<void(StepState)> updateStep,
    NarMemberDatas & narMembers)
{
    assert(BuildResult::TimedOut == 8);

    auto [logFile, logFD] = build_remote::openLogFile(logDir, step->drvPath);
    AutoDelete logFileDel(logFile, false);
    result.logFile = logFile;

    try {

        updateStep(ssConnecting);

        SSHMaster master {
            machine->sshName,
            machine->sshKey,
            machine->sshPublicHostKey,
            false, // no SSH master yet
            false, // no compression yet
            logFD.get(),
        };

        // FIXME: rewrite to use Store.
        auto child = build_remote::openConnection(machine, master);

        {
            auto activeStepState(activeStep->state_.lock());
            if (activeStepState->cancelled) throw Error("step cancelled");
            activeStepState->pid = child->sshPid;
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

        ::Machine::Connection conn {
            {
                .to = child->in.get(),
                .from = child->out.get(),
                /* Handshake. */
                .remoteVersion = 0xdadbeef, // FIXME avoid dummy initialize
            },
            /*.machine =*/ machine,
        };

        Finally updateStats([&]() {
            bytesReceived += conn.from.read;
            bytesSent += conn.to.written;
        });

        constexpr ServeProto::Version our_version = 0x206;

        try {
            conn.remoteVersion = decltype(conn)::handshake(
                conn.to,
                conn.from,
                our_version,
                machine->sshName);
        } catch (EndOfFile & e) {
            child->sshPid.wait();
            std::string s = chomp(readFile(result.logFile));
            throw Error("cannot connect to ‘%1%’: %2%", machine->sshName, s);
        }

        // Do not attempt to speak a newer version of the protocol.
        //
        // Per https://github.com/NixOS/nix/issues/9584 should be handled as
        // part of `handshake` in upstream nix.
        conn.remoteVersion = std::min(conn.remoteVersion, our_version);

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

        StorePathSet outputs;
        for (auto & [_, realisation] : buildResult.builtOutputs)
            outputs.insert(realisation.outPath);

        /* Copy the output paths. */
        if (!machine->isLocalhost() || localStore != std::shared_ptr<Store>(destStore)) {
            updateStep(ssReceivingOutputs);

            MaintainCount<counter> mc(nrStepsCopyingFrom);

            auto now1 = std::chrono::steady_clock::now();

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

        /* Register the outputs of the newly built drv */
        if (experimentalFeatureSettings.isEnabled(Xp::CaDerivations)) {
            auto outputHashes = staticOutputHashes(*localStore, *step->drv);
            for (auto & [outputName, realisation] : buildResult.builtOutputs) {
                // Register the resolved drv output
                destStore->registerDrvOutput(realisation);

                // Also register the unresolved one
                auto unresolvedRealisation = realisation;
                unresolvedRealisation.signatures.clear();
                unresolvedRealisation.id.drvHash = outputHashes.at(outputName);
                destStore->registerDrvOutput(unresolvedRealisation);
            }
        }

        /* Shut down the connection. */
        child->in = -1;
        child->sshPid.wait();

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

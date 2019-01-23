#include <algorithm>
#include <cmath>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "serve-protocol.hh"
#include "state.hh"
#include "util.hh"
#include "worker-protocol.hh"
#include "finally.hh"

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


static void openConnection(Machine::ptr machine, Path tmpDir, int stderrFD, Child & child)
{
    string pgmName;
    Pipe to, from;
    to.create();
    from.create();

    child.pid = startProcess([&]() {

        restoreSignals();

        if (dup2(to.readSide.get(), STDIN_FILENO) == -1)
            throw SysError("cannot dup input pipe to stdin");

        if (dup2(from.writeSide.get(), STDOUT_FILENO) == -1)
            throw SysError("cannot dup output pipe to stdout");

        if (dup2(stderrFD, STDERR_FILENO) == -1)
            throw SysError("cannot dup stderr");

        Strings argv;
        if (machine->sshName == "localhost") {
            pgmName = "nix-store";
            argv = {"nix-store", "--serve", "--write"};
        }
        else {
            pgmName = "ssh";
            argv = {"ssh", machine->sshName};
            if (machine->sshKey != "") append(argv, {"-i", machine->sshKey});
            if (machine->sshPublicHostKey != "") {
                Path fileName = tmpDir + "/host-key";
                auto p = machine->sshName.find("@");
                string host = p != string::npos ? string(machine->sshName, p + 1) : machine->sshName;
                writeFile(fileName, host + " " + machine->sshPublicHostKey + "\n");
                append(argv, {"-oUserKnownHostsFile=" + fileName});
            }
            append(argv,
                { "-x", "-a", "-oBatchMode=yes", "-oConnectTimeout=60", "-oTCPKeepAlive=yes"
                , "--", "nix-store", "--serve", "--write" });
        }

        execvp(argv.front().c_str(), (char * *) stringsToCharPtrs(argv).data()); // FIXME: remove cast

        throw SysError("cannot start %s", pgmName);
    });

    to.readSide = -1;
    from.writeSide = -1;

    child.to = to.writeSide.release();
    child.from = from.readSide.release();
}


static void copyClosureTo(std::timed_mutex & sendMutex, ref<Store> destStore,
    FdSource & from, FdSink & to, const PathSet & paths,
    bool useSubstitutes = false)
{
    PathSet closure;
    for (auto & path : paths)
        destStore->computeFSClosure(path, closure);

    /* Send the "query valid paths" command with the "lock" option
       enabled. This prevents a race where the remote host
       garbage-collect paths that are already there. Optionally, ask
       the remote host to substitute missing paths. */
    // FIXME: substitute output pollutes our build log
    to << cmdQueryValidPaths << 1 << useSubstitutes << closure;
    to.flush();

    /* Get back the set of paths that are already valid on the remote
       host. */
    auto present = readStorePaths<PathSet>(*destStore, from);

    if (present.size() == closure.size()) return;

    Paths sorted = destStore->topoSortPaths(closure);

    Paths missing;
    for (auto i = sorted.rbegin(); i != sorted.rend(); ++i)
        if (present.find(*i) == present.end()) missing.push_back(*i);

    printMsg(lvlDebug, format("sending %1% missing paths") % missing.size());

    std::unique_lock<std::timed_mutex> sendLock(sendMutex,
        std::chrono::seconds(600));

    to << cmdImportPaths;
    destStore->exportPaths(missing, to);
    to.flush();

    if (readInt(from) != 1)
        throw Error("remote machine failed to import closure");
}


void State::buildRemote(ref<Store> destStore,
    Machine::ptr machine, Step::ptr step,
    unsigned int maxSilentTime, unsigned int buildTimeout, unsigned int repeats,
    RemoteResult & result, std::shared_ptr<ActiveStep> activeStep,
    std::function<void(StepState)> updateStep)
{
    assert(BuildResult::TimedOut == 8);

    string base = baseNameOf(step->drvPath);
    result.logFile = logDir + "/" + string(base, 0, 2) + "/" + string(base, 2);
    AutoDelete autoDelete(result.logFile, false);

    createDirs(dirOf(result.logFile));

    AutoCloseFD logFD = open(result.logFile.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0666);
    if (!logFD) throw SysError(format("creating log file ‘%1%’") % result.logFile);

    nix::Path tmpDir = createTempDir();
    AutoDelete tmpDirDel(tmpDir, true);

    try {

        updateStep(ssConnecting);

        Child child;
        openConnection(machine, tmpDir, logFD.get(), child);

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

        FdSource from(child.from.get());
        FdSink to(child.to.get());

        Finally updateStats([&]() {
            bytesReceived += from.read;
            bytesSent += to.written;
        });

        /* Handshake. */
        bool sendDerivation = true;
        unsigned int remoteVersion;

        try {
            to << SERVE_MAGIC_1 << 0x203;
            to.flush();

            unsigned int magic = readInt(from);
            if (magic != SERVE_MAGIC_2)
                throw Error(format("protocol mismatch with ‘nix-store --serve’ on ‘%1%’") % machine->sshName);
            remoteVersion = readInt(from);
            if (GET_PROTOCOL_MAJOR(remoteVersion) != 0x200)
                throw Error(format("unsupported ‘nix-store --serve’ protocol version on ‘%1%’") % machine->sshName);
            if (GET_PROTOCOL_MINOR(remoteVersion) >= 1)
                sendDerivation = false;
            if (GET_PROTOCOL_MINOR(remoteVersion) < 3 && repeats > 0)
                throw Error("machine ‘%1%’ does not support repeating a build; please upgrade it to Nix 1.12", machine->sshName);

        } catch (EndOfFile & e) {
            child.pid.wait();
            string s = chomp(readFile(result.logFile));
            throw Error(format("cannot connect to ‘%1%’: %2%") % machine->sshName % s);
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

        PathSet inputs;
        BasicDerivation basicDrv(step->drv);

        if (sendDerivation)
            inputs.insert(step->drvPath);
        else
            for (auto & p : step->drv.inputSrcs)
                inputs.insert(p);

        for (auto & input : step->drv.inputDrvs) {
            Derivation drv2 = readDerivation(input.first);
            for (auto & name : input.second) {
                auto i = drv2.outputs.find(name);
                if (i == drv2.outputs.end()) continue;
                inputs.insert(i->second.path);
                basicDrv.inputSrcs.insert(i->second.path);
            }
        }

        /* Ensure that the inputs exist in the destination store. This is
           a no-op for regular stores, but for the binary cache store,
           this will copy the inputs to the binary cache from the local
           store. */
        copyClosure(ref<Store>(localStore), destStore, step->drv.inputSrcs, NoRepair, NoCheckSigs);

        /* Copy the input closure. */
        if (/* machine->sshName != "localhost" */ true) {
            auto mc1 = std::make_shared<MaintainCount<counter>>(nrStepsWaiting);
            mc1.reset();
            MaintainCount<counter> mc2(nrStepsCopyingTo);
            printMsg(lvlDebug, format("sending closure of ‘%1%’ to ‘%2%’") % step->drvPath % machine->sshName);

            auto now1 = std::chrono::steady_clock::now();

            copyClosureTo(machine->state->sendLock, destStore, from, to, inputs, true);

            auto now2 = std::chrono::steady_clock::now();

            result.overhead += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();
        }

        autoDelete.cancel();

        /* Truncate the log to get rid of messages about substitutions
           etc. on the remote system. */
        if (lseek(logFD.get(), SEEK_SET, 0) != 0)
            throw SysError("seeking to the start of log file ‘%s’", result.logFile);

        if (ftruncate(logFD.get(), 0) == -1)
            throw SysError("truncating log file ‘%s’", result.logFile);

        logFD = -1;

        /* Do the build. */
        printMsg(lvlDebug, format("building ‘%1%’ on ‘%2%’") % step->drvPath % machine->sshName);

        updateStep(ssBuilding);

        if (sendDerivation)
            to << cmdBuildPaths << PathSet({step->drvPath});
        else
            to << cmdBuildDerivation << step->drvPath << basicDrv;
        to << maxSilentTime << buildTimeout;
        if (GET_PROTOCOL_MINOR(remoteVersion) >= 2)
            to << maxLogSize;
        if (GET_PROTOCOL_MINOR(remoteVersion) >= 3) {
            to << repeats // == build-repeat
               << step->isDeterministic; // == enforce-determinism
        }
        to.flush();

        result.startTime = time(0);
        int res;
        {
            MaintainCount<counter> mc(nrStepsBuilding);
            res = readInt(from);
        }
        result.stopTime = time(0);

        if (sendDerivation) {
            if (res) {
                result.errorMsg = (format("%1% on ‘%2%’") % readString(from) % machine->sshName).str();
                if (res == 100) {
                    result.stepStatus = bsFailed;
                    result.canCache = true;
                }
                else if (res == 101) {
                    result.stepStatus = bsTimedOut;
                }
                else {
                    result.stepStatus = bsAborted;
                    result.canRetry = true;
                }
                return;
            }
            result.stepStatus = bsSuccess;
        } else {
            result.errorMsg = readString(from);
            if (GET_PROTOCOL_MINOR(remoteVersion) >= 3) {
                result.timesBuilt = readInt(from);
                result.isNonDeterministic = readInt(from);
                auto start = readInt(from);
                auto stop = readInt(from);
                if (start && start) {
                    /* Note: this represents the duration of a single
                       round, rather than all rounds. */
                    result.startTime = start;
                    result.stopTime = stop;
                }
            }
            switch ((BuildResult::Status) res) {
                case BuildResult::Built:
                    result.stepStatus = bsSuccess;
                    break;
                case BuildResult::Substituted:
                case BuildResult::AlreadyValid:
                    result.stepStatus = bsSuccess;
                    result.isCached = true;
                    break;
                case BuildResult::PermanentFailure:
                    result.stepStatus = bsFailed;
                    result.canCache = true;
                    result.errorMsg = "";
                    break;
                case BuildResult::InputRejected:
                case BuildResult::OutputRejected:
                    result.stepStatus = bsFailed;
                    result.canCache = true;
                    break;
                case BuildResult::TransientFailure:
                    result.stepStatus = bsFailed;
                    result.canRetry = true;
                    result.errorMsg = "";
                    break;
                case BuildResult::TimedOut:
                    result.stepStatus = bsTimedOut;
                    result.errorMsg = "";
                    break;
                case BuildResult::MiscFailure:
                    result.stepStatus = bsAborted;
                    result.canRetry = true;
                    break;
                case BuildResult::LogLimitExceeded:
                    result.stepStatus = bsLogLimitExceeded;
                    break;
                case BuildResult::NotDeterministic:
                    result.stepStatus = bsNotDeterministic;
                    result.canRetry = false;
                    result.canCache = true;
                    break;
                default:
                    result.stepStatus = bsAborted;
                    break;
            }
            if (result.stepStatus != bsSuccess) return;
        }

        result.errorMsg = "";

        /* If the path was substituted or already valid, then we didn't
           get a build log. */
        if (result.isCached) {
            printMsg(lvlInfo, format("outputs of ‘%1%’ substituted or already valid on ‘%2%’") % step->drvPath % machine->sshName);
            unlink(result.logFile.c_str());
            result.logFile = "";
        }

        /* Copy the output paths. */
        if (/* machine->sshName != "localhost" */ true) {
            updateStep(ssReceivingOutputs);

            MaintainCount<counter> mc(nrStepsCopyingFrom);

            auto now1 = std::chrono::steady_clock::now();

            PathSet outputs;
            for (auto & output : step->drv.outputs)
                outputs.insert(output.second.path);

            /* Query the size of the output paths. */
            size_t totalNarSize = 0;
            to << cmdQueryPathInfos << outputs;
            to.flush();
            while (true) {
                if (readString(from) == "") break;
                readString(from); // deriver
                readStrings<PathSet>(from); // references
                readLongLong(from); // download size
                totalNarSize += readLongLong(from);
            }

            if (totalNarSize > maxOutputSize) {
                result.stepStatus = bsNarSizeLimitExceeded;
                return;
            }

            printMsg(lvlDebug, format("copying outputs of ‘%s’ from ‘%s’ (%d bytes)")
                % step->drvPath % machine->sshName % totalNarSize);

            /* Block until we have the required amount of memory
               available, which is twice the NAR size (namely the
               uncompressed and worst-case compressed NAR), plus 150
               MB for xz compression overhead. (The xz manpage claims
               ~94 MiB, but that's not was I'm seeing.) */
            auto resStart = std::chrono::steady_clock::now();
            size_t compressionCost = totalNarSize + 150 * 1024 * 1024;
            result.tokens = std::make_unique<nix::TokenServer::Token>(memoryTokens.get(totalNarSize + compressionCost));
            auto resStop = std::chrono::steady_clock::now();

            auto resMs = std::chrono::duration_cast<std::chrono::milliseconds>(resStop - resStart).count();
            if (resMs >= 1000)
                printMsg(lvlError, format("warning: had to wait %d ms for %d memory tokens for %s")
                    % resMs % totalNarSize % step->drvPath);

            result.accessor = destStore->getFSAccessor();

            to << cmdExportPaths << 0 << outputs;
            to.flush();
            destStore->importPaths(from, result.accessor, NoCheckSigs);

            /* Release the tokens pertaining to NAR
               compression. After this we only have the uncompressed
               NAR in memory. */
            result.tokens->give_back(compressionCost);

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
            printMsg(lvlInfo, format("will disable machine ‘%1%’ for %2%s") % machine->sshName % delta);
            info->disabledUntil = now + std::chrono::seconds(delta);
        }
        throw;
    }
}

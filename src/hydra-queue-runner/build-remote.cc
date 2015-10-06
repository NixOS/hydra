#include <algorithm>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "misc.hh"
#include "serve-protocol.hh"
#include "state.hh"
#include "util.hh"
#include "worker-protocol.hh"

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
    Pipe to, from;
    to.create();
    from.create();

    child.pid = startProcess([&]() {

        if (dup2(to.readSide, STDIN_FILENO) == -1)
            throw SysError("cannot dup input pipe to stdin");

        if (dup2(from.writeSide, STDOUT_FILENO) == -1)
            throw SysError("cannot dup output pipe to stdout");

        if (dup2(stderrFD, STDERR_FILENO) == -1)
            throw SysError("cannot dup stderr");

        Strings argv;
        if (machine->sshName == "localhost")
            argv = {"nix-store", "--serve", "--write"};
        else {
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

        throw SysError("cannot start ssh");
    });

    to.readSide.close();
    from.writeSide.close();

    child.to = to.writeSide.borrow();
    child.from = from.readSide.borrow();
}


static void copyClosureTo(std::shared_ptr<StoreAPI> store,
    FdSource & from, FdSink & to, const PathSet & paths,
    counter & bytesSent,
    bool useSubstitutes = false)
{
    PathSet closure;
    for (auto & path : paths)
        computeFSClosure(*store, path, closure);

    /* Send the "query valid paths" command with the "lock" option
       enabled. This prevents a race where the remote host
       garbage-collect paths that are already there. Optionally, ask
       the remote host to substitute missing paths. */
    to << cmdQueryValidPaths << 1 << useSubstitutes << closure;
    to.flush();

    /* Get back the set of paths that are already valid on the remote
       host. */
    auto present = readStorePaths<PathSet>(from);

    if (present.size() == closure.size()) return;

    Paths sorted = topoSortPaths(*store, closure);

    Paths missing;
    for (auto i = sorted.rbegin(); i != sorted.rend(); ++i)
        if (present.find(*i) == present.end()) missing.push_back(*i);

    printMsg(lvlDebug, format("sending %1% missing paths") % missing.size());

    for (auto & p : missing)
        bytesSent += store->queryPathInfo(p).narSize;

    to << cmdImportPaths;
    exportPaths(*store, missing, false, to);
    to.flush();

    if (readInt(from) != 1)
        throw Error("remote machine failed to import closure");
}


static void copyClosureFrom(std::shared_ptr<StoreAPI> store,
    FdSource & from, FdSink & to, const PathSet & paths, counter & bytesReceived)
{
    to << cmdExportPaths << 0 << paths;
    to.flush();
    store->importPaths(false, from);

    for (auto & p : paths)
        bytesReceived += store->queryPathInfo(p).narSize;
}


void State::buildRemote(std::shared_ptr<StoreAPI> store,
    Machine::ptr machine, Step::ptr step,
    unsigned int maxSilentTime, unsigned int buildTimeout,
    RemoteResult & result)
{
    string base = baseNameOf(step->drvPath);
    result.logFile = logDir + "/" + string(base, 0, 2) + "/" + string(base, 2);
    AutoDelete autoDelete(result.logFile, false);

    createDirs(dirOf(result.logFile));

    AutoCloseFD logFD(open(result.logFile.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0666));
    if (logFD == -1) throw SysError(format("creating log file ‘%1%’") % result.logFile);

    nix::Path tmpDir = createTempDir();
    AutoDelete tmpDirDel(tmpDir, true);

    Child child;
    openConnection(machine, tmpDir, logFD, child);

    logFD.close();

    FdSource from(child.from);
    FdSink to(child.to);

    /* Handshake. */
    bool sendDerivation = true;
    unsigned int remoteVersion;

    try {
        to << SERVE_MAGIC_1 << 0x202;
        to.flush();

        unsigned int magic = readInt(from);
        if (magic != SERVE_MAGIC_2)
            throw Error(format("protocol mismatch with ‘nix-store --serve’ on ‘%1%’") % machine->sshName);
        remoteVersion = readInt(from);
        if (GET_PROTOCOL_MAJOR(remoteVersion) != 0x200)
            throw Error(format("unsupported ‘nix-store --serve’ protocol version on ‘%1%’") % machine->sshName);
        if (GET_PROTOCOL_MINOR(remoteVersion) >= 1)
            sendDerivation = false;

    } catch (EndOfFile & e) {
        child.pid.wait(true);

        {
            /* Disable this machine until a certain period of time has
               passed. This period increases on every consecutive
               failure. However, don't count failures that occurred
               soon after the last one (to take into account steps
               started in parallel). */
            auto info(machine->state->connectInfo.lock());
            auto now = std::chrono::system_clock::now();
            if (info->consecutiveFailures == 0 || info->lastFailure < now - std::chrono::seconds(30)) {
                info->consecutiveFailures = std::min(info->consecutiveFailures + 1, (unsigned int) 4);
                info->lastFailure = now;
                int delta = retryInterval * powf(retryBackoff, info->consecutiveFailures - 1) + (rand() % 30);
                printMsg(lvlInfo, format("will disable machine ‘%1%’ for %2%s") % machine->sshName % delta);
                info->disabledUntil = now + std::chrono::seconds(delta);
            }
        }

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

    /* Copy the input closure. */
    if (machine->sshName != "localhost") {
        auto mc1 = std::make_shared<MaintainCount>(nrStepsWaiting);
        std::lock_guard<std::mutex> sendLock(machine->state->sendLock);
        mc1.reset();
        MaintainCount mc2(nrStepsCopyingTo);
        printMsg(lvlDebug, format("sending closure of ‘%1%’ to ‘%2%’") % step->drvPath % machine->sshName);
        copyClosureTo(store, from, to, inputs, bytesSent);
    }

    autoDelete.cancel();

    /* Do the build. */
    printMsg(lvlDebug, format("building ‘%1%’ on ‘%2%’") % step->drvPath % machine->sshName);

    if (sendDerivation)
        to << cmdBuildPaths << PathSet({step->drvPath});
    else
        to << cmdBuildDerivation << step->drvPath << basicDrv;
    to << maxSilentTime << buildTimeout;
    if (GET_PROTOCOL_MINOR(remoteVersion) >= 2)
        to << 64 * 1024 * 1024; // == maxLogSize
    to.flush();

    result.startTime = time(0);
    int res;
    {
        MaintainCount mc(nrStepsBuilding);
        res = readInt(from);
    }
    result.stopTime = time(0);

    if (sendDerivation) {
        if (res) {
            result.errorMsg = (format("%1% on ‘%2%’") % readString(from) % machine->sshName).str();
            if (res == 100) result.status = BuildResult::PermanentFailure;
            else if (res == 101) result.status = BuildResult::TimedOut;
            else result.status = BuildResult::MiscFailure;
            return;
        }
        result.status = BuildResult::Built;
    } else {
        result.status = (BuildResult::Status) res;
        result.errorMsg = readString(from);
        if (!result.success()) return;
    }

    /* If the path was substituted or already valid, then we didn't
       get a build log. */
    if (result.status == BuildResult::Substituted || result.status == BuildResult::AlreadyValid) {
        unlink(result.logFile.c_str());
        result.logFile = "";
    }

    /* Copy the output paths. */
    if (machine->sshName != "localhost") {
        printMsg(lvlDebug, format("copying outputs of ‘%1%’ from ‘%2%’") % step->drvPath % machine->sshName);
        PathSet outputs;
        for (auto & output : step->drv.outputs)
            outputs.insert(output.second.path);
        MaintainCount mc(nrStepsCopyingFrom);
        copyClosureFrom(store, from, to, outputs, bytesReceived);
    }

    /* Shut down the connection. */
    child.to.close();
    child.pid.wait(true);
}

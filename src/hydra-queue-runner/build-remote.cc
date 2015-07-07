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


static void openConnection(const string & sshName, const string & sshKey,
    int stderrFD, Child & child)
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
        if (sshName == "localhost")
            argv = {"nix-store", "--serve", "--write"};
        else {
            argv = {"ssh", sshName};
            if (sshKey != "" && sshKey != "-") append(argv, {"-i", sshKey});
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
    TokenServer & copyClosureTokenServer, counter & bytesSent,
    bool useSubstitutes = false)
{
    PathSet closure;
    for (auto & path : paths)
        computeFSClosure(*store, path, closure);

    /* Send the "query valid paths" command with the "lock" option
       enabled. This prevents a race where the remote host
       garbage-collect paths that are already there. Optionally, ask
       the remote host to substitute missing paths. */
    writeInt(cmdQueryValidPaths, to);
    writeInt(1, to); // == lock paths
    writeInt(useSubstitutes, to);
    writeStrings(closure, to);
    to.flush();

    /* Get back the set of paths that are already valid on the remote
       host. */
    auto present = readStorePaths<PathSet>(from);

    if (present.size() == closure.size()) return;

    Paths sorted = topoSortPaths(*store, closure);

    Paths missing;
    for (auto i = sorted.rbegin(); i != sorted.rend(); ++i)
        if (present.find(*i) == present.end()) missing.push_back(*i);

    /* Ensure that only a limited number of threads can copy closures
       at the same time. However, proceed anyway after a timeout to
       prevent starvation by a handful of really huge closures. */
    time_t start = time(0);
    int timeout = 60 * (10 + rand() % 5);
    auto token(copyClosureTokenServer.get(timeout));
    time_t stop = time(0);

    if (token())
        printMsg(lvlDebug, format("got copy closure token after %1%s") % (stop - start));
    else
        printMsg(lvlDebug, format("did not get copy closure token after %1%s") % (stop - start));

    printMsg(lvlDebug, format("sending %1% missing paths") % missing.size());

    for (auto & p : missing)
        bytesSent += store->queryPathInfo(p).narSize;

    writeInt(cmdImportPaths, to);
    exportPaths(*store, missing, false, to);
    to.flush();

    if (readInt(from) != 1)
        throw Error("remote machine failed to import closure");
}


static void copyClosureFrom(std::shared_ptr<StoreAPI> store,
    FdSource & from, FdSink & to, const PathSet & paths, counter & bytesReceived)
{
    writeInt(cmdExportPaths, to);
    writeInt(0, to); // == don't sign
    writeStrings(paths, to);
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

    Child child;
    openConnection(machine->sshName, machine->sshKey, logFD, child);

    logFD.close();

    FdSource from(child.from);
    FdSink to(child.to);

    /* Handshake. */
    try {
        writeInt(SERVE_MAGIC_1, to);
        writeInt(SERVE_PROTOCOL_VERSION, to);
        to.flush();

        unsigned int magic = readInt(from);
        if (magic != SERVE_MAGIC_2)
            throw Error(format("protocol mismatch with ‘nix-store --serve’ on ‘%1%’") % machine->sshName);
        unsigned int version = readInt(from);
        if (GET_PROTOCOL_MAJOR(version) != 0x200)
            throw Error(format("unsupported ‘nix-store --serve’ protocol version on ‘%1%’") % machine->sshName);
    } catch (EndOfFile & e) {
        child.pid.wait(true);
        string s = chomp(readFile(result.logFile));
        throw Error(format("cannot connect to ‘%1%’: %2%") % machine->sshName % s);
    }

    /* Gather the inputs. */
    PathSet inputs({step->drvPath});
    for (auto & input : step->drv.inputDrvs) {
        Derivation drv2 = readDerivation(input.first);
        for (auto & name : input.second) {
            auto i = drv2.outputs.find(name);
            if (i != drv2.outputs.end()) inputs.insert(i->second.path);
        }
    }

    /* Copy the input closure. */
    if (machine->sshName != "localhost") {
        printMsg(lvlDebug, format("sending closure of ‘%1%’ to ‘%2%’") % step->drvPath % machine->sshName);
        MaintainCount mc(nrStepsCopyingTo);
        copyClosureTo(store, from, to, inputs, copyClosureTokenServer, bytesSent);
    }

    autoDelete.cancel();

    /* Do the build. */
    printMsg(lvlDebug, format("building ‘%1%’ on ‘%2%’") % step->drvPath % machine->sshName);
    writeInt(cmdBuildPaths, to);
    writeStrings(PathSet({step->drvPath}), to);
    writeInt(maxSilentTime, to);
    writeInt(buildTimeout, to);
    // FIXME: send maxLogSize.
    to.flush();
    result.startTime = time(0);
    int res;
    {
        MaintainCount mc(nrStepsBuilding);
        res = readInt(from);
    }
    result.stopTime = time(0);
    if (res) {
        result.errorMsg = (format("%1% on ‘%2%’") % readString(from) % machine->sshName).str();
        if (res == 100) result.status = RemoteResult::rrPermanentFailure;
        else if (res == 101) result.status = RemoteResult::rrTimedOut;
        else result.status = RemoteResult::rrMiscFailure;
        return;
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

    result.status = RemoteResult::rrSuccess;
}

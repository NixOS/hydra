#include <algorithm>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "build-remote.hh"

#include "util.hh"
#include "misc.hh"
#include "serve-protocol.hh"
#include "worker-protocol.hh"

using namespace nix;


struct Child
{
    Pid pid;
    AutoCloseFD to, from;
};


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

        Strings argv({"ssh", sshName, "-i", sshKey, "-x", "-a", "--", "nix-store", "--serve", "--write"});

        execvp("ssh", (char * *) stringsToCharPtrs(argv).data()); // FIXME: remove cast

        throw SysError("cannot start ssh");
    });

    to.readSide.close();
    from.writeSide.close();

    child.to = to.writeSide.borrow();
    child.from = from.readSide.borrow();
}


static void copyClosureTo(std::shared_ptr<StoreAPI> store,
    FdSource & from, FdSink & to, const PathSet & paths,
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

    printMsg(lvlError, format("sending %1% missing paths") % missing.size());

    writeInt(cmdImportPaths, to);
    exportPaths(*store, missing, false, to);
    to.flush();

    if (readInt(from) != 1)
        throw Error("remote machine failed to import closure");
}


static void copyClosureFrom(std::shared_ptr<StoreAPI> store,
    FdSource & from, FdSink & to, const PathSet & paths)
{
    writeInt(cmdExportPaths, to);
    writeInt(0, to); // == don't sign
    writeStrings(paths, to);
    to.flush();
    store->importPaths(false, from);
}


void buildRemote(std::shared_ptr<StoreAPI> store,
    const string & sshName, const string & sshKey,
    const Path & drvPath, const Derivation & drv,
    const nix::Path & logDir, RemoteResult & result)
{
    string base = baseNameOf(drvPath);
    Path logFile = logDir + "/" + string(base, 0, 2) + "/" + string(base, 2);

    createDirs(dirOf(logFile));

    AutoCloseFD logFD(open(logFile.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0666));
    if (logFD == -1) throw SysError(format("creating log file ‘%1%’") % logFile);

    Child child;
    openConnection(sshName, sshKey, logFD, child);

    logFD.close();

    FdSource from(child.from);
    FdSink to(child.to);

    /* Handshake. */
    writeInt(SERVE_MAGIC_1, to);
    writeInt(SERVE_PROTOCOL_VERSION, to);
    to.flush();

    unsigned int magic = readInt(from);
    if (magic != SERVE_MAGIC_2)
        throw Error(format("protocol mismatch with ‘nix-store --serve’ on ‘%1%’") % sshName);
    unsigned int version = readInt(from);
    if (GET_PROTOCOL_MAJOR(version) != 0x200)
        throw Error(format("unsupported ‘nix-store --serve’ protocol version on ‘%1%’") % sshName);

    /* Copy the input closure. */
    printMsg(lvlError, format("sending closure of ‘%1%’ to ‘%2%’") % drvPath % sshName);
    copyClosureTo(store, from, to, PathSet({drvPath}));

    /* Do the build. */
    printMsg(lvlError, format("building ‘%1%’ on ‘%2%’") % drvPath % sshName);
    writeInt(cmdBuildPaths, to);
    writeStrings(PathSet({drvPath}), to);
    writeInt(3600, to); // == maxSilentTime, FIXME
    writeInt(7200, to); // == buildTimeout, FIXME
    to.flush();
    result.startTime = time(0);
    int res = readInt(from);
    result.stopTime = time(0);
    if (res) {
        result.errorMsg = (format("%1% on ‘%2%’") % readString(from) % sshName).str();
        if (res == 100) result.status = RemoteResult::rrPermanentFailure;
        else if (res == 101) result.status = RemoteResult::rrTimedOut;
        else result.status = RemoteResult::rrMiscFailure;
        return;
    }

    /* Copy the output paths. */
    printMsg(lvlError, format("copying outputs of ‘%1%’ from ‘%2%’") % drvPath % sshName);
    PathSet outputs;
    for (auto & output : drv.outputs)
        outputs.insert(output.second.path);
    copyClosureFrom(store, from, to, outputs);

    /* Shut down the connection. */
    child.to.close();
    child.pid.wait(true);

    result.status = RemoteResult::rrSuccess;
}

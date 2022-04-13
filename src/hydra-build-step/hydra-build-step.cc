/* This is a helper program that performs a build step, i.e. a single
   derivation. In addition to a derivation path, it takes three store
   URLs as arguments:

   * --store: The store that will hold the resulting store paths
       (typically a binary cache).

   * --eval-store: The store that holds the .drv files, as produced by
       hydra-evaluator.

   * --build-store: The store that performs the build (often a
       SSHStore for remote builds).

   The build log is written to the path indicated by --log-file.
*/

#include "shared.hh"
#include "common-eval-args.hh"
#include "store-api.hh"
#include "build-result.hh"
#include "derivations.hh"
#include "worker-protocol.hh"

#include <chrono>

using namespace nix;

// FIXME: cut&paste
static std::string_view getS(const std::vector<Logger::Field> & fields, size_t n)
{
    assert(n < fields.size());
    assert(fields[n].type == Logger::Field::tString);
    return fields[n].s;
}

void mainWrapped(std::list<std::string> args)
{
    verbosity = lvlError;

    struct MyArgs : MixEvalArgs, MixCommonArgs
    {
        Path drvPath;
        std::optional<std::string> buildStoreUrl;
        std::optional<Path> logPath;
        std::optional<uint64_t> maxOutputSize;

        MyArgs() : MixCommonArgs("hydra-build-step")
        {
            expectArg("drv-path", &drvPath);

            addFlag({
                .longName = "build-store",
                .description = "The Nix store to use for building the derivation.",
                //.category = category,
                .labels = {"store-url"},
                .handler = {&buildStoreUrl},
            });

            addFlag({
                .longName = "log-file",
                .description = "The path to the build log.",
                .labels = {"path"},
                .handler = {&logPath},
            });

            addFlag({
                .longName = "max-output-size",
                .description = "Maximum size of the outputs.",
                .labels = {"bytes"},
                .handler = {&maxOutputSize},
            });
        }
    };

    /* A logger that intercepts all build log lines and writes them to
       the log file. */
    MyArgs myArgs;
    myArgs.parseCmdline(args);

    struct MyLogger : public Logger
    {
        Logger & prev;
        AutoCloseFD logFile;

        MyLogger(Logger & prev, Path logPath) : prev(prev)
        {
            logFile = open(logPath.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0666);
            if (!logFile)
                throw SysError("creating log file '%s'", logPath);
        }

        void log(Verbosity lvl, const FormatOrString & fs) override
        { prev.log(lvl, fs); }

        void logEI(const ErrorInfo & ei) override
        { prev.logEI(ei); }

        void writeToStdout(std::string_view s) override
        { prev.writeToStdout(s); }

        void result(ActivityId act, ResultType type, const Fields & fields) override
        {
            if (type == resBuildLogLine)
                writeLine(logFile.get(), std::string(getS(fields, 0)));
            else
                prev.result(act, type, fields);
        }
    };

    auto destStore = openStore();
    auto evalStore = myArgs.evalStoreUrl ? openStore(*myArgs.evalStoreUrl) : destStore;
    auto buildStore = myArgs.buildStoreUrl ? openStore(*myArgs.buildStoreUrl) : destStore;

    auto drvPath = evalStore->parseStorePath(myArgs.drvPath);

    auto drv = evalStore->readDerivation(drvPath);
    BasicDerivation basicDrv(drv);

    uint64_t overhead = 0;

    /* Gather the inputs. */
    StorePathSet inputs;

    for (auto & p : drv.inputSrcs)
        inputs.insert(p);

    for (auto & input : drv.inputDrvs) {
        auto drv2 = evalStore->readDerivation(input.first);
        for (auto & name : input.second) {
            if (auto i = get(drv2.outputs, name)) {
                auto outPath = i->path(*evalStore, drv2.name, name);
                inputs.insert(*outPath);
                basicDrv.inputSrcs.insert(*outPath);
            }
        }
    }

    /* Ensure that the inputs exist in the destination store (so that
       the builder can substitute them from the destination
       store). This is a no-op for regular stores, but for the binary
       cache store, this will copy the inputs to the binary cache from
       the local store. */
    {
        auto now1 = std::chrono::steady_clock::now();

        debug("sending closure of '%s' to '%s'",
            evalStore->printStorePath(drvPath), destStore->getUri());

        if (evalStore != destStore)
            copyClosure(*evalStore, *destStore, drv.inputSrcs, NoRepair, NoCheckSigs);

        copyClosure(*destStore, *buildStore, inputs, NoRepair, NoCheckSigs, Substitute);

        auto now2 = std::chrono::steady_clock::now();

        overhead += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();
    }

    /* Perform the build. */
    if (myArgs.logPath)
        logger = new MyLogger(*logger, *myArgs.logPath);

    auto buildResult = buildStore->buildDerivation(drvPath, basicDrv);

    /* Copy the output paths from the build store to the destination
       store. */
    size_t totalNarSize = 0;

    if (buildResult.success()) {

        std::map<StorePath, ValidPathInfo> infos;
        StorePathSet outputs;
        for (auto & [output, realisation] : buildResult.builtOutputs) {
            auto info = buildStore->queryPathInfo(realisation.outPath);
            totalNarSize += info->narSize;
            infos.insert_or_assign(info->path, *info);
            outputs.insert(info->path);
        }

        if ((!myArgs.maxOutputSize || totalNarSize <= *myArgs.maxOutputSize)
            && buildStore != destStore)
        {
            debug("copying outputs of '%s' from '%s' (%d bytes)",
                buildStore->printStorePath(drvPath), buildStore->getUri(), totalNarSize);

            auto now1 = std::chrono::steady_clock::now();

            copyPaths(*buildStore, *destStore, outputs, NoRepair, NoCheckSigs);

            auto now2 = std::chrono::steady_clock::now();

            overhead += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();
        }
    }

    FdSink stdout(STDOUT_FILENO);
    stdout << overhead;
    stdout << totalNarSize;
    worker_proto::write(*evalStore, stdout, buildResult);
}

int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();
        mainWrapped(argvToStrings(argc, argv));
    });
}

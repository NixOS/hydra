#include <map>
#include <iostream>

#define GC_LINUX_THREADS 1
#include <gc/gc_allocator.h>

#include "shared.hh"
#include "store-api.hh"
#include "eval.hh"
#include "eval-inline.hh"
#include "util.hh"
#include "json.hh"
#include "get-drvs.hh"
#include "globals.hh"
#include "common-eval-args.hh"

#include "hydra-config.hh"

#include <sys/types.h>
#include <sys/wait.h>

using namespace nix;


static Path gcRootsDir;


static void findJobs(EvalState & state, JSONObject & top,
    Bindings & autoArgs, Value & v, const string & attrPath);


static string queryMetaStrings(EvalState & state, DrvInfo & drv, const string & name)
{
    Strings res;
    std::function<void(Value & v)> rec;

    rec = [&](Value & v) {
        state.forceValue(v);
        if (v.type == tString)
            res.push_back(v.string.s);
        else if (v.isList())
            for (unsigned int n = 0; n < v.listSize(); ++n)
                rec(*v.listElems()[n]);
        else if (v.type == tAttrs) {
            auto a = v.attrs->find(state.symbols.create("shortName"));
            if (a != v.attrs->end())
                res.push_back(state.forceString(*a->value));
        }
    };

    Value * v = drv.queryMeta(name);
    if (v) rec(*v);

    return concatStringsSep(", ", res);
}


static std::string lastAttrPath;
static bool comma = false;
static size_t maxHeapSize;


struct BailOut { };


bool lte(const std::string & s1, const std::string & s2)
{
    size_t p1 = 0, p2 = 0;

    while (true) {
        if (p1 == s1.size()) return p2 == s2.size();
        if (p2 == s2.size()) return true;

        auto d1 = s1.find('.', p1);
        auto d2 = s2.find('.', p2);

        auto c = s1.compare(p1, d1 - p1, s2, p2, d2 - p2);

        if (c < 0) return true;
        if (c > 0) return false;

        p1 = d1 == std::string::npos ? s1.size() : d1 + 1;
        p2 = d2 == std::string::npos ? s2.size() : d2 + 1;
    }
}


static void findJobsWrapped(EvalState & state, JSONObject & top,
    Bindings & autoArgs, Value & vIn, const string & attrPath)
{
    if (lastAttrPath != "" && lte(attrPath, lastAttrPath)) return;

    debug(format("at path `%1%'") % attrPath);

    checkInterrupt();

    Value v;
    state.autoCallFunction(autoArgs, vIn, v);

    if (v.type == tAttrs) {

        auto drv = getDerivation(state, v, false);

        if (drv) {
            Path drvPath;

            DrvInfo::Outputs outputs = drv->queryOutputs();

            if (drv->querySystem() == "unknown")
                throw EvalError("derivation must have a ‘system’ attribute");

            if (comma) { std::cout << ","; comma = false; }

            {
            auto res = top.object(attrPath);
            res.attr("nixName", drv->queryName());
            res.attr("system", drv->querySystem());
            res.attr("drvPath", drvPath = drv->queryDrvPath());
            res.attr("description", drv->queryMetaString("description"));
            res.attr("license", queryMetaStrings(state, *drv, "license"));
            res.attr("homepage", drv->queryMetaString("homepage"));
            res.attr("maintainers", queryMetaStrings(state, *drv, "maintainers"));
            res.attr("schedulingPriority", drv->queryMetaInt("schedulingPriority", 100));
            res.attr("timeout", drv->queryMetaInt("timeout", 36000));
            res.attr("maxSilent", drv->queryMetaInt("maxSilent", 7200));
            res.attr("isChannel", drv->queryMetaBool("isHydraChannel", false));

            /* If this is an aggregate, then get its constituents. */
            Bindings::iterator a = v.attrs->find(state.symbols.create("_hydraAggregate"));
            if (a != v.attrs->end() && state.forceBool(*a->value, *a->pos)) {
                Bindings::iterator a = v.attrs->find(state.symbols.create("constituents"));
                if (a == v.attrs->end())
                    throw EvalError("derivation must have a ‘constituents’ attribute");
                PathSet context;
                state.coerceToString(*a->pos, *a->value, context, true, false);
                PathSet drvs;
                for (auto & i : context)
                    if (i.at(0) == '!') {
                        size_t index = i.find("!", 1);
                        drvs.insert(string(i, index + 1));
                    }
                res.attr("constituents", concatStringsSep(" ", drvs));
            }

            /* Register the derivation as a GC root.  !!! This
               registers roots for jobs that we may have already
               done. */
            auto localStore = state.store.dynamic_pointer_cast<LocalFSStore>();
            if (gcRootsDir != "" && localStore) {
                Path root = gcRootsDir + "/" + baseNameOf(drvPath);
                if (!pathExists(root)) localStore->addPermRoot(drvPath, root, false);
            }

            auto res2 = res.object("outputs");
            for (auto & j : outputs)
                res2.attr(j.first, j.second);

            }

            GC_prof_stats_s gc;
            GC_get_prof_stats(&gc, sizeof(gc));

            if (gc.heapsize_full > maxHeapSize) {
                printInfo("restarting hydra-eval-jobs after job '%s' because heap size is at %d bytes", attrPath, gc.heapsize_full);
                lastAttrPath = attrPath;
                throw BailOut();
            }
        }

        else {
            if (!state.isDerivation(v)) {
                for (auto & i : v.attrs->lexicographicOrder()) {
                    std::string name(i->name);

                    /* Skip jobs with dots in the name. */
                    if (name.find('.') != std::string::npos) {
                        printError("skipping job with illegal name '%s'", name);
                        continue;
                    }

                    findJobs(state, top, autoArgs, *i->value,
                        (attrPath.empty() ? "" : attrPath + ".") + name);
                }
            }
        }
    }

    else if (v.type == tNull) {
        // allow null values, meaning 'do nothing'
    }

    else
        throw TypeError(format("unsupported value: %1%") % v);
}


static void findJobs(EvalState & state, JSONObject & top,
    Bindings & autoArgs, Value & v, const string & attrPath)
{
    try {
        findJobsWrapped(state, top, autoArgs, v, attrPath);
    } catch (EvalError & e) {
        if (comma) { std::cout << ","; comma = false; }
        auto res = top.object(attrPath);
        res.attr("error", filterANSIEscapes(e.msg(), true));
    }
}


int main(int argc, char * * argv)
{
    assert(lte("abc", "def"));
    assert(lte("abc", "def.foo"));
    assert(!lte("def", "abc"));
    assert(lte("nixpkgs.hello", "nixpkgs"));
    assert(lte("nixpkgs.hello", "nixpkgs.hellooo"));
    assert(lte("gitAndTools.git-annex.x86_64-darwin", "gitAndTools.git-annex.x86_64-linux"));
    assert(lte("gitAndTools.git-annex.x86_64-linux", "gitAndTools.git-annex-remote-b2.aarch64-linux"));

    /* Prevent undeclared dependencies in the evaluation via
       $NIX_PATH. */
    unsetenv("NIX_PATH");

    return handleExceptions(argv[0], [&]() {

        auto config = std::make_unique<::Config>();

        auto initialHeapSize = config->getStrOption("evaluator_initial_heap_size", "");
        if (initialHeapSize != "")
            setenv("GC_INITIAL_HEAP_SIZE", initialHeapSize.c_str(), 1);

        maxHeapSize = config->getIntOption("evaluator_max_heap_size", 1UL << 30);

        initNix();
        initGC();

        Path releaseExpr;

        struct MyArgs : LegacyArgs, MixEvalArgs
        {
            using LegacyArgs::LegacyArgs;
        };

        MyArgs myArgs(baseNameOf(argv[0]), [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--gc-roots-dir")
                gcRootsDir = getArg(*arg, arg, end);
            else if (*arg == "--dry-run")
                settings.readOnlyMode = true;
            else if (*arg != "" && arg->at(0) == '-')
                return false;
            else
                releaseExpr = *arg;
            return true;
        });

        myArgs.parseCmdline(argvToStrings(argc, argv));

        JSONObject json(std::cout, true);
        std::cout.flush();

        do {

            Pipe pipe;
            pipe.create();

            ProcessOptions options;
            options.allowVfork = false;

            GC_atfork_prepare();

            auto pid = startProcess([&]() {
                pipe.readSide = -1;

                GC_atfork_child();
                GC_start_mark_threads();

                if (lastAttrPath != "") debug("resuming from '%s'", lastAttrPath);

                /* FIXME: The build hook in conjunction with import-from-derivation is causing "unexpected EOF" during eval */
                settings.builders = "";

                /* Prevent access to paths outside of the Nix search path and
                   to the environment. */
                evalSettings.restrictEval = true;

                if (releaseExpr == "") throw UsageError("no expression specified");

                if (gcRootsDir == "") printMsg(lvlError, "warning: `--gc-roots-dir' not specified");

                EvalState state(myArgs.searchPath, openStore());

                Bindings & autoArgs = *myArgs.getAutoArgs(state);

                Value v;
                state.evalFile(lookupFileArg(state, releaseExpr), v);

                comma = lastAttrPath != "";

                try {
                    findJobs(state, json, autoArgs, v, "");
                    lastAttrPath = "";
                } catch (BailOut &) { }

                writeFull(pipe.writeSide.get(), lastAttrPath);

                exit(0);
            }, options);

            GC_atfork_parent();

            pipe.writeSide = -1;

            int status;
            while (true) {
                checkInterrupt();
                if (waitpid(pid, &status, 0) == pid) break;
                if (errno != EINTR) continue;
            }

            if (status != 0)
                throw Exit(WIFEXITED(status) ? WEXITSTATUS(status) : 99);

            maxHeapSize += 64 * 1024 * 1024;

            lastAttrPath = drainFD(pipe.readSide.get());
        } while (lastAttrPath != "");
    });
}

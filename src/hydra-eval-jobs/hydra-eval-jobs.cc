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
#include "flakeref.hh"
#include "flake.hh"

#include "hydra-config.hh"

#include <sys/types.h>
#include <sys/wait.h>

using namespace nix;


static Path gcRootsDir;


static void findJobs(EvalState & state, JSONObject & top,
    Bindings & autoArgs, Value & v, const string & attrPath);


static string queryMetaStrings(EvalState & state, DrvInfo & drv, const string & name, const string & subAttribute)
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
            auto a = v.attrs->find(state.symbols.create(subAttribute));
            if (a != v.attrs->end())
                res.push_back(state.forceString(*a->value));
        }
    };

    Value * v = drv.queryMeta(name);
    if (v) rec(*v);

    return concatStringsSep(", ", res);
}


static void findJobsWrapped(EvalState & state, JSONObject & top,
    Bindings & autoArgs, Value & vIn, const string & attrPath)
{
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

            {
            auto res = top.object(attrPath);
            res.attr("nixName", drv->queryName());
            res.attr("system", drv->querySystem());
            res.attr("drvPath", drvPath = drv->queryDrvPath());
            res.attr("description", drv->queryMetaString("description"));
            res.attr("license", queryMetaStrings(state, *drv, "license", "shortName"));
            res.attr("homepage", drv->queryMetaString("homepage"));
            res.attr("maintainers", queryMetaStrings(state, *drv, "maintainers", "email"));
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
        auto res = top.object(attrPath);
        res.attr("error", filterANSIEscapes(e.msg(), true));
    }
}


int main(int argc, char * * argv)
{
    /* Prevent undeclared dependencies in the evaluation via
       $NIX_PATH. */
    unsetenv("NIX_PATH");

    return handleExceptions(argv[0], [&]() {

        auto config = std::make_unique<::Config>();

        auto initialHeapSize = config->getStrOption("evaluator_initial_heap_size", "");
        if (initialHeapSize != "")
            setenv("GC_INITIAL_HEAP_SIZE", initialHeapSize.c_str(), 1);

        initNix();
        initGC();

        struct MyArgs : MixEvalArgs, MixCommonArgs
        {
            Path releaseExpr;
            bool flake = false;

            MyArgs() : MixCommonArgs("hydra-eval-jobs")
            {
                mkFlag()
                    .longName("help")
                    .description("show usage information")
                    .handler([&]() {
                        printHelp(programName, std::cout);
                        throw Exit();
                    });

                mkFlag()
                    .longName("gc-roots-dir")
                    .description("garbage collector roots directory")
                    .labels({"path"})
                    .dest(&gcRootsDir);

                mkFlag()
                    .longName("dry-run")
                    .description("don't create store derivations")
                    .set(&settings.readOnlyMode, true);

                mkFlag()
                    .longName("flake")
                    .description("build a flake")
                    .set(&flake, true);

                expectArg("expr", &releaseExpr);
            }
        };

        MyArgs myArgs;
        myArgs.parseCmdline(argvToStrings(argc, argv));

        JSONObject json(std::cout, true);
        std::cout.flush();

        /* FIXME: The build hook in conjunction with import-from-derivation is causing "unexpected EOF" during eval */
        settings.builders = "";

        /* Prevent access to paths outside of the Nix search path and
           to the environment. */
        evalSettings.restrictEval = true;

        /* When building a flake, use pure evaluation (no access to
           'getEnv', 'currentSystem' etc. */
        evalSettings.pureEval = myArgs.flake;

        if (myArgs.releaseExpr == "") throw UsageError("no expression specified");

        if (gcRootsDir == "") printMsg(lvlError, "warning: `--gc-roots-dir' not specified");

        EvalState state(myArgs.searchPath, openStore());

        Bindings & autoArgs = *myArgs.getAutoArgs(state);

        Value v;

        if (myArgs.flake) {
            FlakeRef flakeRef(myArgs.releaseExpr);
            auto vFlake = state.allocValue();
            makeFlakeValue(state, flakeRef, AllPure, *vFlake);

            auto vProvides = (*vFlake->attrs->get(state.symbols.create("provides")))->value;
            state.forceValue(*vProvides);

            auto aHydraJobs = vProvides->attrs->get(state.symbols.create("hydraJobs"));
            if (!aHydraJobs)
                throw Error("flake '%s' does not provide any Hydra jobs", flakeRef);

            v = *(*aHydraJobs)->value;

        } else {
            state.evalFile(lookupFileArg(state, myArgs.releaseExpr), v);
        }

        findJobs(state, json, autoArgs, v, "");
    });
}

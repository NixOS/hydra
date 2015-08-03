#include <map>
#include <iostream>

#include <gc/gc_allocator.h>

#include "shared.hh"
#include "store-api.hh"
#include "eval.hh"
#include "eval-inline.hh"
#include "util.hh"
#include "value-to-json.hh"
#include "get-drvs.hh"
#include "common-opts.hh"
#include "globals.hh"

using namespace nix;


static Path gcRootsDir;


typedef std::list<Value *, traceable_allocator<Value *> > ValueList;
typedef std::map<Symbol, ValueList> AutoArgs;


static void findJobs(EvalState & state, JSONObject & top,
    const AutoArgs & argsLeft, Value & v, const string & attrPath);


static void tryJobAlts(EvalState & state, JSONObject & top,
    const AutoArgs & argsLeft, const string & attrPath, Value & fun,
    Formals::Formals_::iterator cur,
    Formals::Formals_::iterator last,
    Bindings & actualArgs) // FIXME: should be const
{
    if (cur == last) {
        Value v, * arg = state.allocValue();
        state.mkAttrs(*arg, 0);
        arg->attrs = &actualArgs;
        mkApp(v, fun, *arg);
        findJobs(state, top, argsLeft, v, attrPath);
        return;
    }

    AutoArgs::const_iterator a = argsLeft.find(cur->name);

    Formals::Formals_::iterator next = cur; ++next;

    if (a == argsLeft.end()) {
        if (!cur->def)
            throw TypeError(format("job `%1%' requires an argument named `%2%'")
                % attrPath % cur->name);
        tryJobAlts(state, top, argsLeft, attrPath, fun, next, last, actualArgs);
        return;
    }

    int n = 0;
    foreach (ValueList::const_iterator, i, a->second) {
        Bindings & actualArgs2(*state.allocBindings(actualArgs.size() + 1)); // !!! inefficient
        for (auto & i: actualArgs)
            actualArgs2.push_back(i);
        AutoArgs argsLeft2(argsLeft);
        actualArgs2.push_back(Attr(cur->name, *i));
        actualArgs2.sort(); // !!! inefficient
        argsLeft2.erase(cur->name);
        tryJobAlts(state, top, argsLeft2, attrPath, fun, next, last, actualArgs2);
        ++n;
    }
}


static string queryMetaStrings(EvalState & state, DrvInfo & drv, const string & name)
{
    Value * v = drv.queryMeta(name);
    if (v) {
        state.forceValue(*v);
        if (v->type == tString)
            return v->string.s;
        else if (v->type == tList) {
            string res = "";
            for (unsigned int n = 0; n < v->list.length; ++n) {
                Value v2(*v->list.elems[n]);
                state.forceValue(v2);
                if (v2.type == tString) {
                    if (res.size() != 0) res += ", ";
                    res += v2.string.s;
                }
            }
            return res;
        }
    }
    return "";
}


static void findJobsWrapped(EvalState & state, JSONObject & top,
    const AutoArgs & argsLeft, Value & v, const string & attrPath)
{
    debug(format("at path `%1%'") % attrPath);

    checkInterrupt();

    state.forceValue(v);

    if (v.type == tAttrs) {

        DrvInfo drv(state);

        if (getDerivation(state, v, drv, false)) {
            Path drvPath;

            DrvInfo::Outputs outputs = drv.queryOutputs();

            if (drv.system == "unknown")
                throw EvalError("derivation must have a ‘system’ attribute");

            {
            top.attr(attrPath);
            JSONObject res(top.str);
            res.attr("nixName", drv.name);
            res.attr("system", drv.system);
            res.attr("drvPath", drvPath = drv.queryDrvPath());
            res.attr("description", drv.queryMetaString("description"));
            res.attr("license", queryMetaStrings(state, drv, "license"));
            res.attr("homepage", drv.queryMetaString("homepage"));
            res.attr("maintainers", queryMetaStrings(state, drv, "maintainers"));
            res.attr("schedulingPriority", drv.queryMetaInt("schedulingPriority", 100));
            res.attr("timeout", drv.queryMetaInt("timeout", 36000));
            res.attr("maxSilent", drv.queryMetaInt("maxSilent", 7200));

            /* If this is an aggregate, then get its constituents. */
            Bindings::iterator a = v.attrs->find(state.symbols.create("_hydraAggregate"));
            if (a != v.attrs->end() && state.forceBool(*a->value)) {
                Bindings::iterator a = v.attrs->find(state.symbols.create("constituents"));
                if (a == v.attrs->end())
                    throw EvalError("derivation must have a ‘constituents’ attribute");
                PathSet context;
                state.coerceToString(*a->pos, *a->value, context, true, false);
                PathSet drvs;
                foreach (PathSet::iterator, i, context)
                    if (i->at(0) == '!') {
                        size_t index = i->find("!", 1);
                        drvs.insert(string(*i, index + 1));
                    }
                res.attr("constituents", concatStringsSep(" ", drvs));
            }

            /* Register the derivation as a GC root.  !!! This
               registers roots for jobs that we may have already
               done. */
            if (gcRootsDir != "") {
                Path root = gcRootsDir + "/" + baseNameOf(drvPath);
                if (!pathExists(root)) addPermRoot(*store, drvPath, root, false);
            }

            res.attr("outputs");
            JSONObject res2(res.str);
            for (auto & j : outputs)
                res2.attr(j.first, j.second);

            }
            top.str << std::endl;
        }

        else {
            if (!state.isDerivation(v)) {
                foreach (Bindings::iterator, i, *v.attrs)
                    findJobs(state, top, argsLeft, *i->value,
                        (attrPath.empty() ? "" : attrPath + ".") + (string) i->name);
            }
        }
    }

    else if (v.type == tLambda && v.lambda.fun->matchAttrs) {
        if (v.lambda.fun->matchAttrs) {
            Bindings & tmp(*state.allocBindings(0));
            tryJobAlts(state, top, argsLeft, attrPath, v,
                v.lambda.fun->formals->formals.begin(),
                v.lambda.fun->formals->formals.end(),
                tmp);
        }
        else {
            /* Pass all the remaining args. */
            Value v2, * arg = state.allocValue();
            state.mkAttrs(*arg, argsLeft.size());
            for (const auto & arg : argsLeft) {
                if (arg.second.size() != 1) {
                    /* Currently don't support multiple values for an arg, so
                     * fall back on the old behavior
                     */
                    throw TypeError(format("unsupported value: %1%") % v);
                }
                arg->attrs->push_back(Attr(arg.first, arg.second.front()));
            }
            arg->attrs.sort();
            mkApp(v, v2, *arg);
            findJobs(state, top, argsLeft, v2, attrPath);
            return;
        }
    }

    else if (v.type == tNull) {
        // allow null values, meaning 'do nothing'
    }

    else
        throw TypeError(format("unsupported value: %1%") % v);
}


static void findJobs(EvalState & state, JSONObject & top,
    const AutoArgs & argsLeft, Value & v, const string & attrPath)
{
    try {
        findJobsWrapped(state, top, argsLeft, v, attrPath);
    } catch (EvalError & e) {
        {
        top.attr(attrPath);
        JSONObject res(top.str);
        res.attr("error", e.msg());
        }
        top.str << std::endl;
    }
}


int main(int argc, char * * argv)
{
    /* Prevent undeclared dependencies in the evaluation via
       $NIX_PATH. */
    unsetenv("NIX_PATH");

    return handleExceptions(argv[0], [&]() {
        initNix();
        initGC();

        Strings searchPath;
        Path releaseExpr;
        std::map<string, Strings> autoArgs_;

        parseCmdLine(argc, argv, [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--arg" || *arg == "--argstr") {
                /* This is like --arg in nix-instantiate, except that it
                   supports multiple versions for the same argument.
                   That is, autoArgs is a mapping from variable names to
                   *lists* of values. */
                auto what = *arg;
                string name = getArg(what, arg, end);
                string value = getArg(what, arg, end);
                autoArgs_[name].push_back((what == "--arg" ? 'E' : 'S') + value);
            }
            else if (parseSearchPathArg(arg, end, searchPath))
                ;
            else if (*arg == "--gc-roots-dir")
                gcRootsDir = getArg(*arg, arg, end);
            else if (*arg == "--dry-run")
                settings.readOnlyMode = true;
            else if (*arg != "" && arg->at(0) == '-')
                return false;
            else
                releaseExpr = absPath(*arg);
            return true;
        });

        /* Prevent access to paths outside of the Nix search path and
           to the environment. */
        settings.set("restrict-eval", "true");

        if (releaseExpr == "") throw UsageError("no expression specified");

        if (gcRootsDir == "") printMsg(lvlError, "warning: `--gc-roots-dir' not specified");

        EvalState state(searchPath);

        AutoArgs autoArgs;
        for (auto & i : autoArgs_) {
            for (auto & j : i.second) {
                Value * v = state.allocValue();
                if (j[0] == 'E')
                    state.eval(state.parseExprFromString(string(j, 1), absPath(".")), *v);
                else
                    mkString(*v, string(j, 1));
                autoArgs[state.symbols.create(i.first)].push_back(v);
            }
        }

        store = openStore();

        Value v;
        state.evalFile(releaseExpr, v);

        JSONObject json(std::cout);
        findJobs(state, json, autoArgs, v, "");

        state.printStats();
    });
}

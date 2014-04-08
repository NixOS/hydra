#include <map>
#include <iostream>

#include <gc/gc_allocator.h>

#include "shared.hh"
#include "store-api.hh"
#include "eval.hh"
#include "eval-inline.hh"
#include "util.hh"
#include "xml-writer.hh"
#include "get-drvs.hh"
#include "common-opts.hh"

using namespace nix;


void printHelp()
{
    std::cout << "Syntax: hydra-eval-jobs <expr>\n";
}


static Path gcRootsDir;


typedef std::map<Symbol, std::pair<unsigned int, Value *> > ArgsUsed;
typedef std::list<Value *, traceable_allocator<Value *> > ValueList;
typedef std::map<Symbol, ValueList> AutoArgs;


static void findJobs(EvalState & state, XMLWriter & doc,
    const ArgsUsed & argsUsed, const AutoArgs & argsLeft,
    Value & v, const string & attrPath);


static void tryJobAlts(EvalState & state, XMLWriter & doc,
    const ArgsUsed & argsUsed, const AutoArgs & argsLeft,
    const string & attrPath, Value & fun,
    Formals::Formals_::iterator cur,
    Formals::Formals_::iterator last,
    const Bindings & actualArgs)
{
    if (cur == last) {
        Value v, * arg = state.allocValue();
        state.mkAttrs(*arg, 0);
        *arg->attrs = actualArgs;
        mkApp(v, fun, *arg);
        findJobs(state, doc, argsUsed, argsLeft, v, attrPath);
        return;
    }

    AutoArgs::const_iterator a = argsLeft.find(cur->name);

    Formals::Formals_::iterator next = cur; ++next;

    if (a == argsLeft.end()) {
        if (!cur->def)
            throw TypeError(format("job `%1%' requires an argument named `%2%'")
                % attrPath % cur->name);
        tryJobAlts(state, doc, argsUsed, argsLeft, attrPath, fun, next, last, actualArgs);
        return;
    }

    int n = 0;
    foreach (ValueList::const_iterator, i, a->second) {
        Bindings actualArgs2(actualArgs); // !!! inefficient
        ArgsUsed argsUsed2(argsUsed);
        AutoArgs argsLeft2(argsLeft);
        actualArgs2.push_back(Attr(cur->name, *i));
        actualArgs2.sort(); // !!! inefficient
        argsUsed2[cur->name] = std::pair<unsigned int, Value *>(n, *i);
        argsLeft2.erase(cur->name);
        tryJobAlts(state, doc, argsUsed2, argsLeft2, attrPath, fun, next, last, actualArgs2);
        ++n;
    }
}


static void showArgsUsed(XMLWriter & doc, const ArgsUsed & argsUsed)
{
    foreach (ArgsUsed::const_iterator, i, argsUsed) {
        XMLAttrs xmlAttrs2;
        xmlAttrs2["name"] = i->first;
        xmlAttrs2["value"] = (format("%1%") % *i->second.second).str();
        xmlAttrs2["altnr"] = int2String(i->second.first);
        doc.writeEmptyElement("arg", xmlAttrs2);
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


static void findJobsWrapped(EvalState & state, XMLWriter & doc,
    const ArgsUsed & argsUsed, const AutoArgs & argsLeft,
    Value & v, const string & attrPath)
{
    debug(format("at path `%1%'") % attrPath);

    checkInterrupt();

    state.forceValue(v);

    if (v.type == tAttrs) {

        DrvInfo drv(state);

        if (getDerivation(state, v, drv, false)) {
            XMLAttrs xmlAttrs;
            Path drvPath;

            DrvInfo::Outputs outputs = drv.queryOutputs();

            xmlAttrs["jobName"] = attrPath;
            xmlAttrs["nixName"] = drv.name;
            xmlAttrs["system"] = drv.system;
            xmlAttrs["drvPath"] = drvPath = drv.queryDrvPath();
            xmlAttrs["description"] = drv.queryMetaString("description");
            xmlAttrs["longDescription"] = drv.queryMetaString("longDescription");
            xmlAttrs["license"] = queryMetaStrings(state, drv, "license");
            xmlAttrs["homepage"] = drv.queryMetaString("homepage");
            xmlAttrs["maintainers"] = queryMetaStrings(state, drv, "maintainers");

            xmlAttrs["schedulingPriority"] = int2String(drv.queryMetaInt("schedulingPriority", 100));

            xmlAttrs["timeout"] = int2String(drv.queryMetaInt("timeout", 36000));

            xmlAttrs["maxSilent"] = int2String(drv.queryMetaInt("maxSilent", 3600));

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
                xmlAttrs["constituents"] = concatStringsSep(" ", drvs);
            }

            /* Register the derivation as a GC root.  !!! This
               registers roots for jobs that we may have already
               done. */
            if (gcRootsDir != "") {
                Path root = gcRootsDir + "/" + baseNameOf(drvPath);
                if (!pathExists(root)) addPermRoot(*store, drvPath, root, false);
            }

            XMLOpenElement _(doc, "job", xmlAttrs);

            foreach (DrvInfo::Outputs::iterator, j, outputs) {
                XMLAttrs attrs2;
                attrs2["name"] = j->first;
                attrs2["path"] = j->second;
                doc.writeEmptyElement("output", attrs2);
            }

            showArgsUsed(doc, argsUsed);
        }

        else {
            if (!state.isDerivation(v)) {
                foreach (Bindings::iterator, i, *v.attrs)
                    findJobs(state, doc, argsUsed, argsLeft, *i->value,
                        (attrPath.empty() ? "" : attrPath + ".") + (string) i->name);
            }
        }
    }

    else if (v.type == tLambda && v.lambda.fun->matchAttrs) {
        tryJobAlts(state, doc, argsUsed, argsLeft, attrPath, v,
            v.lambda.fun->formals->formals.begin(),
            v.lambda.fun->formals->formals.end(),
            Bindings());
    }

    else if (v.type == tNull) {
        // allow null values, meaning 'do nothing'
    }

    else
        throw TypeError(format("unsupported value: %1%") % v);
}


static void findJobs(EvalState & state, XMLWriter & doc,
    const ArgsUsed & argsUsed, const AutoArgs & argsLeft,
    Value & v, const string & attrPath)
{
    try {
        findJobsWrapped(state, doc, argsUsed, argsLeft, v, attrPath);
    } catch (EvalError & e) {
        XMLAttrs xmlAttrs;
        xmlAttrs["location"] = attrPath;
        xmlAttrs["msg"] = e.msg();
        XMLOpenElement _(doc, "error", xmlAttrs);
        showArgsUsed(doc, argsUsed);
    }
}


void run(Strings args)
{
    /* Prevent undeclared dependencies in the evaluation via
       $NIX_PATH. */
    unsetenv("NIX_PATH");

    EvalState state;
    Path releaseExpr;
    AutoArgs autoArgs;

    for (Strings::iterator i = args.begin(); i != args.end(); ) {
        string arg = *i++;
        if (arg == "--arg" || arg == "--argstr") {
            /* This is like --arg in nix-instantiate, except that it
               supports multiple versions for the same argument.
               That is, autoArgs is a mapping from variable names to
               *lists* of values. */
            if (i == args.end()) throw UsageError("missing argument");
            string name = *i++;
            if (i == args.end()) throw UsageError("missing argument");
            string value = *i++;
            Value * v = state.allocValue();
            if (arg == "--arg")
                state.eval(state.parseExprFromString(value, absPath(".")), *v);
            else
                mkString(*v, value);
            autoArgs[state.symbols.create(name)].push_back(v);
        }
        else if (arg == "--gc-roots-dir") {
            if (i == args.end()) throw UsageError("missing argument");
            gcRootsDir = *i++;
        }
        else if (parseSearchPathArg(arg, i, args.end(), state))
            ;
        else if (arg[0] == '-')
            throw UsageError(format("unknown flag `%1%'") % arg);
        else
            releaseExpr = arg;
    }

    if (releaseExpr == "") throw UsageError("no expression specified");

    if (gcRootsDir == "") printMsg(lvlError, "warning: `--gc-roots-dir' not specified");

    store = openStore();

    Value v;
    state.evalFile(releaseExpr, v);

    XMLWriter doc(true, std::cout);
    XMLOpenElement root(doc, "jobs");
    findJobs(state, doc, ArgsUsed(), autoArgs, v, "");

    state.printStats();
}


string programId = "hydra-eval-jobs";

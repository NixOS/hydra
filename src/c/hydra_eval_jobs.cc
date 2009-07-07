#include <map>
#include <iostream>

#include "shared.hh"
#include "store-api.hh"
#include "eval.hh"
#include "parser.hh"
#include "nixexpr-ast.hh"
#include "util.hh"
#include "xml-writer.hh"
#include "get-drvs.hh"

using namespace nix;


void printHelp()
{
    std::cout << "Syntax: eval-jobs <expr>\n";
}


static Path gcRootsDir;


Expr evalAttr(EvalState & state, Expr e)
{
    return e ? evalExpr(state, e) : e;
}


static void findJobs(EvalState & state, XMLWriter & doc,
    const ATermMap & argsUsed, const ATermMap & argsLeft,
    Expr e, const string & attrPath);


static void tryJobAlts(EvalState & state, XMLWriter & doc,
    const ATermMap & argsUsed, const ATermMap & argsLeft,
    const string & attrPath, Expr fun,
    ATermList formals, const ATermMap & actualArgs)
{
    if (formals == ATempty) {
        findJobs(state, doc, argsUsed, argsLeft,
            makeCall(fun, makeAttrs(actualArgs)), attrPath);
        return;
    }

    Expr name; ATerm def2; ATermList values;
    if (!matchFormal(ATgetFirst(formals), name, def2)) abort();
    
    if ((values = (ATermList) argsLeft.get(name))) {
        int n = 0;
        for (ATermIterator i(ATreverse(values)); i; ++i, ++n) {
            ATermMap actualArgs2(actualArgs);
            ATermMap argsUsed2(argsUsed);
            ATermMap argsLeft2(argsLeft);
            actualArgs2.set(name, makeAttrRHS(*i, makeNoPos()));
            argsUsed2.set(name, (ATerm) ATmakeList2(*i, (ATerm) ATmakeInt(n)));
            argsLeft2.remove(name);
            tryJobAlts(state, doc, argsUsed2, argsLeft2, attrPath, fun, ATgetNext(formals), actualArgs2);
        }
    }
    
    else
        throw TypeError(format("job `%1%' requires an argument named `%2%'")
            % attrPath % aterm2String(name));
}


static void showArgsUsed(XMLWriter & doc, const ATermMap & argsUsed)
{
    foreach (ATermMap::const_iterator, i, argsUsed) {
        XMLAttrs xmlAttrs2;
        xmlAttrs2["name"] = aterm2String(i->key);
        xmlAttrs2["value"] = showValue(ATelementAt((ATermList) i->value, 0));
        xmlAttrs2["altnr"] = int2String(ATgetInt((ATermInt) ATelementAt((ATermList) i->value, 1)));
        doc.writeEmptyElement("arg", xmlAttrs2);
    }
}


static string queryMetaFieldString(MetaInfo & meta, const string & name)
{
    MetaValue value = meta[name];
    if (value.type != MetaValue::tpString) return "";
    return value.stringValue;
}

    
static int queryMetaFieldInt(MetaInfo & meta, const string & name, int def)
{
    MetaValue value = meta[name];
    if (value.type == MetaValue::tpInt) return value.intValue;
    if (value.type == MetaValue::tpString) {
        int n;
        if (string2Int(value.stringValue, n)) return n;
    }
    return def;
}

    
static void findJobsWrapped(EvalState & state, XMLWriter & doc,
    const ATermMap & argsUsed, const ATermMap & argsLeft,
    Expr e, const string & attrPath)
{
    debug(format("at path `%1%'") % attrPath);
    
    e = evalExpr(state, e);

    ATermList as, formals;
    ATermBool ellipsis;
    ATerm pat, body, pos;
    string s;
    PathSet context;
    
    if (matchAttrs(e, as)) {
        ATermMap attrs;
        queryAllAttrs(e, attrs);

        DrvInfo drv;
        
        if (getDerivation(state, e, drv)) {
            XMLAttrs xmlAttrs;
            Path drvPath;

            xmlAttrs["jobName"] = attrPath;
            xmlAttrs["nixName"] = drv.name;
            xmlAttrs["system"] = drv.system;
            xmlAttrs["drvPath"] = drvPath = drv.queryDrvPath(state);
            xmlAttrs["outPath"] = drv.queryOutPath(state);
            MetaInfo meta = drv.queryMetaInfo(state);
            xmlAttrs["description"] = queryMetaFieldString(meta, "description");
            xmlAttrs["longDescription"] = queryMetaFieldString(meta, "longDescription");
            xmlAttrs["license"] = queryMetaFieldString(meta, "license");
            xmlAttrs["homepage"] = queryMetaFieldString(meta, "homepage");
            int prio = queryMetaFieldInt(meta, "schedulingPriority", 100);
            xmlAttrs["schedulingPriority"] = int2String(prio);

            string maintainers;
            MetaValue value = meta["maintainers"];
            if (value.type == MetaValue::tpString)
                maintainers = value.stringValue;
            else if (value.type == MetaValue::tpStrings) {
                foreach (Strings::const_iterator, i, value.stringValues) {
                    if (maintainers.size() != 0) maintainers += ", ";
                    maintainers += *i;
                }
            }
            xmlAttrs["maintainers"] = maintainers;

            /* Register the derivation as a GC root.  !!! This
               registers roots for jobs that we may have already
               done. */
            Path root = gcRootsDir + "/" + baseNameOf(drvPath);
            if (!pathExists(root)) addPermRoot(drvPath, root, false);
            
            XMLOpenElement _(doc, "job", xmlAttrs);
            showArgsUsed(doc, argsUsed);
        }

        else {
            foreach (ATermMap::const_iterator, i, attrs)
                findJobs(state, doc, argsUsed, argsLeft, i->value,
                    (attrPath.empty() ? "" : attrPath + ".") + aterm2String(i->key));
        }
    }

    else if (matchFunction(e, pat, body, pos) && matchAttrsPat(pat, formals, ellipsis)) {
        tryJobAlts(state, doc, argsUsed, argsLeft, attrPath, e, formals, ATermMap());
    }

    else
        throw TypeError(format("unknown value: %1%") % showValue(e));
}


static void findJobs(EvalState & state, XMLWriter & doc,
    const ATermMap & argsUsed, const ATermMap & argsLeft,
    Expr e, const string & attrPath)
{
    try {
        findJobsWrapped(state, doc, argsUsed, argsLeft, e, attrPath);
    } catch (Error & e) {
        XMLAttrs xmlAttrs;
        xmlAttrs["location"] = attrPath;
        xmlAttrs["msg"] = e.msg();
        XMLOpenElement _(doc, "error", xmlAttrs);
        showArgsUsed(doc, argsUsed);
    }
}


void run(Strings args)
{
    EvalState state;
    Path releaseExpr;
    ATermMap autoArgs;
    
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
            Expr e = arg == "--arg"
                ? evalExpr(state, parseExprFromString(state, value, absPath(".")))
                : makeStr(value);
            autoArgs.set(toATerm(name), (ATerm) ATinsert(autoArgs.get(toATerm(name))
                    ? (ATermList) autoArgs.get(toATerm(name))
                    : ATempty, e));
        }
        else if (arg == "--gc-roots-dir") {
            if (i == args.end()) throw UsageError("missing argument");
            gcRootsDir = *i++;
        }
        else if (arg[0] == '-')
            throw UsageError(format("unknown flag `%1%'") % arg);
        else
            releaseExpr = arg;
    }

    if (releaseExpr == "") throw UsageError("no expression specified");
    
    if (gcRootsDir == "") throw UsageError("--gc-roots-dir not specified");
    
    store = openStore();

    Expr e = parseExprFromFile(state, releaseExpr);

    XMLWriter doc(true, std::cout);
    XMLOpenElement root(doc, "jobs");
    findJobs(state, doc, ATermMap(), autoArgs, e, "");
}


string programId = "eval-jobs";

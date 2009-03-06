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


Expr evalAttr(EvalState & state, Expr e)
{
    return e ? evalExpr(state, e) : e;
}


static void findJobs(EvalState & state, XMLWriter & doc,
    Expr e, const string & attrPath)
{
    std::cerr << "at `" << attrPath << "'\n";
    
    e = evalExpr(state, e);

    ATermList as, es, formals;
    ATermBool ellipsis;
    ATerm pat, body, pos;
    string s;
    PathSet context;
    
    if (matchAttrs(e, as)) {
        ATermMap attrs;
        queryAllAttrs(e, attrs);

        DrvInfo drv;
        
        if (getDerivation(state, e, drv)) {
            std::cerr << "derivation\n";
            
            XMLAttrs xmlAttrs;
            Path outPath, drvPath;

            xmlAttrs["name"] = attrPath;
            xmlAttrs["system"] = drv.system;
            xmlAttrs["drvPath"] = drv.queryDrvPath(state);
            xmlAttrs["outPath"] = drv.queryOutPath(state);
            xmlAttrs["description"] = drv.queryMetaInfo(state, "description");
            xmlAttrs["longDescription"] = drv.queryMetaInfo(state, "longDescription");
            xmlAttrs["license"] = drv.queryMetaInfo(state, "license");
            xmlAttrs["homepage"] = drv.queryMetaInfo(state, "homepage");
        
            XMLOpenElement _(doc, "job", xmlAttrs);
        }

        else {
            std::cerr << "attrset\n";
            foreach (ATermMap::const_iterator, i, attrs)
                findJobs(state, doc, i->value,
                    (attrPath.empty() ? "" : attrPath + ".") + aterm2String(i->key));
        }
    }

    else if (matchFunction(e, pat, body, pos) && matchAttrsPat(pat, formals, ellipsis)) {
        std::cerr << "function\n";

        ATermMap actualArgs(ATgetLength(formals));
        
        for (ATermIterator i(formals); i; ++i) {
            Expr name, def, value; ATerm def2;
            if (!matchFormal(*i, name, def2)) abort();
        }
    }
        
    else 
        std::cerr << showValue(e) << "\n";
}


void run(Strings args)
{
    EvalState state;
    Path releaseExpr;
    
    for (Strings::iterator i = args.begin(); i != args.end(); ) {
        string arg = *i++;
        if (arg[0] == '-')
            throw UsageError(format("unknown flag `%1%'") % arg);
        else
            releaseExpr = arg;
    }

    store = openStore();

    Expr e = parseExprFromFile(state, releaseExpr);

    XMLWriter doc(true, std::cout);
    XMLOpenElement root(doc, "jobs");
    findJobs(state, doc, e, "");
}


string programId = "eval-jobs";

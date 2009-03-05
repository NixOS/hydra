#include <map>
#include <iostream>

#include "shared.hh"
#include "store-api.hh"
#include "eval.hh"
#include "parser.hh"
#include "nixexpr-ast.hh"
#include "util.hh"
#include "xml-writer.hh"

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

    ATermList as, es;
    ATerm pat, body, pos;
    string s;
    PathSet context;
    
    if (matchAttrs(e, as)) {
        ATermMap attrs;
        queryAllAttrs(e, attrs);

        Expr a = evalAttr(state, attrs.get(toATerm("type")));
        if (a && matchStr(a, s, context) && s == "derivation") {
            std::cerr << "derivation\n";

            XMLAttrs xmlAttrs;
            Path outPath, drvPath;

            xmlAttrs["name"] = attrPath;
            
            a = evalAttr(state, attrs.get(toATerm("drvPath")));
            if (matchStr(a, drvPath, context)) xmlAttrs["drvPath"] = drvPath;
        
            a = evalAttr(state, attrs.get(toATerm("outPath")));
            if (matchStr(a, outPath, context)) xmlAttrs["outPath"] = outPath;

            XMLOpenElement _(doc, "job", xmlAttrs);
        }

        else {
            std::cerr << "attrset\n";
            foreach (ATermMap::const_iterator, i, attrs)
                findJobs(state, doc, i->value,
                    (attrPath.empty() ? "" : attrPath + ".") + aterm2String(i->key));
        }
    }

    else if (matchFunction(e, pat, body, pos)) {
        std::cerr << "function\n";
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

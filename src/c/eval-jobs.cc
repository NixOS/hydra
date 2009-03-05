#include <map>
#include <iostream>

#include "shared.hh"
#include "store-api.hh"
#include "eval.hh"
#include "parser.hh"
#include "expr-to-xml.hh"

using namespace nix;


void printHelp()
{
    std::cout << "Syntax: eval-jobs <expr>\n";
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

    Expr e = evalExpr(state, parseExprFromFile(state, releaseExpr));
    
    PathSet context;
    printTermAsXML(e, std::cout, context);
}


string programId = "eval-jobs";

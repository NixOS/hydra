#include <iostream>
#include <thread>
#include <optional>
#include <unordered_map>

#include "shared.hh"
#include "store-api.hh"
#include "eval.hh"
#include "eval-gc.hh"
#include "eval-inline.hh"
#include "eval-settings.hh"
#include "signals.hh"
#include "terminal.hh"
#include "util.hh"
#include "get-drvs.hh"
#include "globals.hh"
#include "common-eval-args.hh"
#include "flake/flakeref.hh"
#include "flake/flake.hh"
#include "attr-path.hh"
#include "derivations.hh"
#include "local-fs-store.hh"

#include "hydra-config.hh"

#include <sys/types.h>
#include <sys/wait.h>
#include <sys/resource.h>

#include <fnmatch.h>

#include <nlohmann/json.hpp>

void check_pid_status_nonblocking(pid_t check_pid)
{
    // Only check 'initialized' and known PID's
    if (check_pid <= 0) { return; }

    int wstatus = 0;
    pid_t pid = waitpid(check_pid, &wstatus, WNOHANG);
    // -1 = failure, WNOHANG: 0 = no change
    if (pid <= 0) { return; }

    std::cerr << "child process (" << pid << ") ";

    if (WIFEXITED(wstatus)) {
        std::cerr << "exited with status=" << WEXITSTATUS(wstatus) << std::endl;
    } else if (WIFSIGNALED(wstatus)) {
        std::cerr << "killed by signal=" << WTERMSIG(wstatus) << std::endl;
    } else if (WIFSTOPPED(wstatus)) {
        std::cerr << "stopped by signal=" << WSTOPSIG(wstatus) << std::endl;
    } else if (WIFCONTINUED(wstatus)) {
        std::cerr << "continued" << std::endl;
    }
}

using namespace nix;

static Path gcRootsDir;
static size_t maxMemorySize;

struct MyArgs : MixEvalArgs, MixCommonArgs, RootArgs
{
    Path releaseExpr;
    bool flake = false;
    bool dryRun = false;

    MyArgs() : MixCommonArgs("hydra-eval-jobs")
    {
        addFlag({
            .longName = "gc-roots-dir",
            .description = "garbage collector roots directory",
            .labels = {"path"},
            .handler = {&gcRootsDir}
        });

        addFlag({
            .longName = "dry-run",
            .description = "don't create store derivations",
            .handler = {&dryRun, true}
        });

        addFlag({
            .longName = "flake",
            .description = "build a flake",
            .handler = {&flake, true}
        });

        expectArg("expr", &releaseExpr);
    }
};

static MyArgs myArgs;

static std::string queryMetaStrings(EvalState & state, PackageInfo & drv, const std::string & name, const std::string & subAttribute)
{
    Strings res;
    std::function<void(Value & v)> rec;

    rec = [&](Value & v) {
        state.forceValue(v, noPos);
        if (v.type() == nString)
            res.emplace_back(v.string_view());
        else if (v.isList())
            for (unsigned int n = 0; n < v.listSize(); ++n)
                rec(*v.listElems()[n]);
        else if (v.type() == nAttrs) {
            auto a = v.attrs()->find(state.symbols.create(subAttribute));
            if (a != v.attrs()->end())
                res.push_back(std::string(state.forceString(*a->value, a->pos, "while evaluating meta attributes")));
        }
    };

    Value * v = drv.queryMeta(name);
    if (v) rec(*v);

    return concatStringsSep(", ", res);
}

static void worker(
    EvalState & state,
    Bindings & autoArgs,
    AutoCloseFD & to,
    AutoCloseFD & from)
{
    Value vTop;

    if (myArgs.flake) {
        using namespace flake;

        auto [flakeRef, fragment, outputSpec] = parseFlakeRefWithFragmentAndExtendedOutputsSpec(fetchSettings, myArgs.releaseExpr, absPath("."));

        auto vFlake = state.allocValue();

        auto lockedFlake = lockFlake(
                flakeSettings,
                state,
                flakeRef,
            LockFlags {
                .updateLockFile = false,
                .useRegistries = false,
                .allowUnlocked = false,
            });

        callFlake(state, lockedFlake, *vFlake);

        auto vOutputs = vFlake->attrs()->get(state.symbols.create("outputs"))->value;
        state.forceValue(*vOutputs, noPos);

        auto aHydraJobs = vOutputs->attrs()->get(state.symbols.create("hydraJobs"));
        if (!aHydraJobs)
            aHydraJobs = vOutputs->attrs()->get(state.symbols.create("checks"));
        if (!aHydraJobs)
            throw Error("flake '%s' does not provide any Hydra jobs or checks", flakeRef);

        vTop = *aHydraJobs->value;

    } else {
        state.evalFile(lookupFileArg(state, myArgs.releaseExpr), vTop);
    }

    auto vRoot = state.allocValue();
    state.autoCallFunction(autoArgs, vTop, *vRoot);

    size_t prev = 0;
    auto start = std::chrono::steady_clock::now();

    while (true) {
        /* Wait for the master to send us a job name. */
        writeLine(to.get(), "next");

        auto s = readLine(from.get());
        if (s == "exit") break;
        if (!hasPrefix(s, "do ")) abort();
        std::string attrPath(s, 3);

        debug("worker process %d at '%s'", getpid(), attrPath);

        /* Evaluate it and send info back to the master. */
        nlohmann::json reply;

        try {
            auto vTmp = findAlongAttrPath(state, attrPath, autoArgs, *vRoot).first;

            auto v = state.allocValue();
            state.autoCallFunction(autoArgs, *vTmp, *v);

            if (auto drv = getDerivation(state, *v, false)) {

                // CA derivations do not have static output paths, so we
                // have to defensively not query output paths in case we
                // encounter one.
                PackageInfo::Outputs outputs = drv->queryOutputs(
                    !experimentalFeatureSettings.isEnabled(Xp::CaDerivations));

                if (drv->querySystem() == "unknown")
                    state.error<EvalError>("derivation must have a 'system' attribute").debugThrow();

                auto drvPath = state.store->printStorePath(drv->requireDrvPath());

                nlohmann::json job;

                job["nixName"] = drv->queryName();
                job["system"] =drv->querySystem();
                job["drvPath"] = drvPath;
                job["description"] = drv->queryMetaString("description");
                job["license"] = queryMetaStrings(state, *drv, "license", "shortName");
                job["homepage"] = drv->queryMetaString("homepage");
                job["maintainers"] = queryMetaStrings(state, *drv, "maintainers", "email");
                job["schedulingPriority"] = drv->queryMetaInt("schedulingPriority", 100);
                job["timeout"] = drv->queryMetaInt("timeout", 36000);
                job["maxSilent"] = drv->queryMetaInt("maxSilent", 7200);
                job["isChannel"] = drv->queryMetaBool("isHydraChannel", false);

                /* If this is an aggregate, then get its constituents. */
                auto a = v->attrs()->get(state.symbols.create("_hydraAggregate"));
                if (a && state.forceBool(*a->value, a->pos, "while evaluating the `_hydraAggregate` attribute")) {
                    auto a = v->attrs()->get(state.symbols.create("constituents"));
                    if (!a)
                        state.error<EvalError>("derivation must have a ‘constituents’ attribute").debugThrow();

                    NixStringContext context;
                    state.coerceToString(a->pos, *a->value, context, "while evaluating the `constituents` attribute", true, false);
                    for (auto & c : context)
                        std::visit(overloaded {
                            [&](const NixStringContextElem::Built & b) {
                                job["constituents"].push_back(b.drvPath->to_string(*state.store));
                            },
                            [&](const NixStringContextElem::Opaque & o) {
                            },
                            [&](const NixStringContextElem::DrvDeep & d) {
                            },
                        }, c.raw);

                    state.forceList(*a->value, a->pos, "while evaluating the `constituents` attribute");
                    for (unsigned int n = 0; n < a->value->listSize(); ++n) {
                        auto v = a->value->listElems()[n];
                        state.forceValue(*v, noPos);
                        if (v->type() == nString)
                            job["namedConstituents"].push_back(v->string_view());
                    }

                    auto glob = v->attrs()->get(state.symbols.create("_hydraGlobConstituents"));
                    bool globConstituents = glob && state.forceBool(*glob->value, glob->pos, "while evaluating the `_hydraGlobConstituents` attribute");
                    job["globConstituents"] = globConstituents;
                }

                /* Register the derivation as a GC root.  !!! This
                   registers roots for jobs that we may have already
                   done. */
                auto localStore = state.store.dynamic_pointer_cast<LocalFSStore>();
                if (gcRootsDir != "" && localStore) {
                    Path root = gcRootsDir + "/" + std::string(baseNameOf(drvPath));
                    if (!pathExists(root))
                        localStore->addPermRoot(localStore->parseStorePath(drvPath), root);
                }

                nlohmann::json out;
                for (auto & [outputName, optOutputPath] : outputs) {
                    if (optOutputPath) {
                        out[outputName] = state.store->printStorePath(*optOutputPath);
                    } else {
                        // See the `queryOutputs` call above; we should
                        // not encounter missing output paths otherwise.
                        assert(experimentalFeatureSettings.isEnabled(Xp::CaDerivations));
                        out[outputName] = nullptr;
                    }
                }
                job["outputs"] = std::move(out);
                reply["job"] = std::move(job);
            }

            else if (v->type() == nAttrs) {
                auto attrs = nlohmann::json::array();
                StringSet ss;
                for (auto & i : v->attrs()->lexicographicOrder(state.symbols)) {
                    std::string name(state.symbols[i->name]);
                    if (name.find(' ') != std::string::npos) {
                        printError("skipping job with illegal name '%s'", name);
                        continue;
                    }
                    attrs.push_back(name);
                }
                reply["attrs"] = std::move(attrs);
            }

            else if (v->type() == nNull)
                ;

            else state.error<TypeError>("attribute '%s' is %s, which is not supported", attrPath, showType(*v)).debugThrow();

        } catch (EvalError & e) {
            auto msg = e.msg();
            // Transmits the error we got from the previous evaluation
            // in the JSON output.
            reply["error"] = filterANSIEscapes(msg, true);
            // Don't forget to print it into the STDERR log, this is
            // what's shown in the Hydra UI.
            printError(msg);
        }

        writeLine(to.get(), reply.dump());

        /* If our RSS exceeds the maximum, exit. The master will
           start a new process. */

        auto end = std::chrono::steady_clock::now();
        auto duration = std::chrono::duration_cast<std::chrono::seconds>(start - end).count();
        struct rusage r;
        getrusage(RUSAGE_SELF, &r);
        size_t delta = (size_t)r.ru_maxrss - prev; // KiB
        if (delta > maxMemorySize * 1024 * 0.5 || (duration > 1))
          printError("evaluating job '%s' increased memory usage by %d MiB", attrPath,
                     (r.ru_maxrss - prev)/1024);

        prev = r.ru_maxrss;
        if ((size_t) r.ru_maxrss > maxMemorySize * 1024) break;
    }

    writeLine(to.get(), "restart");
}

struct DependencyCycle : public std::exception {
    std::string a;
    std::string b;
    std::set<std::string> remainingAggregates;

    DependencyCycle(const std::string & a, const std::string & b, const std::set<std::string> & remainingAggregates) : a(a), b(b), remainingAggregates(remainingAggregates) {}

    std::string what() {
        return fmt("Dependency cycle: %s <-> %s", a, b);
    }
};

struct AggregateJob
{
    std::string name;
    std::set<std::string> dependencies;
    std::unordered_map<std::string, std::string> brokenJobs;

    bool operator<(const AggregateJob & b) const { return name < b.name; }
};

// This is copied from `libutil/topo-sort.hh` in CppNix and slightly modified.
// However, I needed a way to use strings as identifiers to sort, but still be able
// to put AggregateJob objects into this function since I'd rather not
// have to transform back and forth between a list of strings and AggregateJobs
// in resolveNamedConstituents.
std::vector<AggregateJob> topoSort(std::set<AggregateJob> items)
{
    std::vector<AggregateJob> sorted;
    std::set<std::string> visited, parents;

    std::map<std::string, AggregateJob> dictIdentToObject;
    for (auto & it : items) {
        dictIdentToObject.insert({it.name, it});
    }

    std::function<void(const std::string & path, const std::string * parent)> dfsVisit;

    dfsVisit = [&](const std::string & path, const std::string * parent) {
        if (parents.count(path)) {
            dictIdentToObject.erase(path);
            dictIdentToObject.erase(*parent);
            std::set<std::string> remaining;
            for (auto & [k, _] : dictIdentToObject) {
                remaining.insert(k);
            }
            throw DependencyCycle(path, *parent, remaining);
        }

        if (!visited.insert(path).second) return;
        parents.insert(path);

        std::set<std::string> references = dictIdentToObject[path].dependencies;

        for (auto & i : references)
            /* Don't traverse into items that don't exist in our starting set. */
            if (i != path && dictIdentToObject.find(i) != dictIdentToObject.end())
                dfsVisit(i, &path);

        sorted.push_back(dictIdentToObject[path]);
        parents.erase(path);
    };

    for (auto & [i, _] : dictIdentToObject)
        dfsVisit(i, nullptr);

    return sorted;
}

static bool insertMatchingConstituents(const std::string & childJobName,
        const std::string & jobName,
        std::function<bool(const std::string &, nlohmann::json &)> isBroken,
        nlohmann::json & jobs,
        std::set<std::string> & results)
{
    bool expansionFound = false;
    for (auto job = jobs.begin(); job != jobs.end(); job++) {
        // Never select the job itself as constituent. Trivial way
        // to avoid obvious cycles.
        if (job.key() == jobName) {
            continue;
        }
        auto jobName = job.key();
        if (fnmatch(childJobName.c_str(), jobName.c_str(), 0) == 0 && !isBroken(jobName, *job)) {
            results.insert(jobName);
            expansionFound = true;
        }
    }

    return expansionFound;
}

static std::vector<AggregateJob> resolveNamedConstituents(nlohmann::json & jobs)
{
    std::set<AggregateJob> aggregateJobs;
    for (auto i = jobs.begin(); i != jobs.end(); ++i) {
        auto jobName = i.key();
        auto & job = i.value();

        auto named = job.find("namedConstituents");
        if (named != job.end()) {
            bool globConstituents = job.value<bool>("globConstituents", false);
            std::unordered_map<std::string, std::string> brokenJobs;
            std::set<std::string> results;

            auto isBroken = [&brokenJobs, &jobName](
                    const std::string & childJobName, nlohmann::json & job) -> bool {
                if (job.find("error") != job.end()) {
                    std::string error = job["error"];
                    printError("aggregate job '%s' references broken job '%s': %s", jobName, childJobName, error);
                    brokenJobs[childJobName] = error;
                    return true;
                } else {
                    return false;
                }
            };

            for (const std::string & childJobName : *named) {
                auto childJob = jobs.find(childJobName);
                if (childJob == jobs.end()) {
                    if (!globConstituents) {
                        printError("aggregate job '%s' references non-existent job '%s'", jobName, childJobName);
                        brokenJobs[childJobName] = "does not exist";
                    } else if (!insertMatchingConstituents(childJobName, jobName, isBroken, jobs, results)) {
                        warn("aggregate job '%s' references constituent glob pattern '%s' with no matches", jobName, childJobName);
                        brokenJobs[childJobName] = "constituent glob pattern had no matches";
                    }
                } else if (!isBroken(childJobName, *childJob)) {
                    results.insert(childJobName);
                }
            }

            aggregateJobs.insert(AggregateJob(jobName, results, brokenJobs));
        }
    }

    return topoSort(aggregateJobs);
}

static void rewriteAggregates(nlohmann::json & jobs,
        std::vector<AggregateJob> aggregateJobs,
        bool dryRun,
        ref<Store> store)
{
    for (auto & aggregateJob : aggregateJobs) {
        auto & job = jobs.find(aggregateJob.name).value();
        if (dryRun) {
            for (auto & childJobName : aggregateJob.dependencies) {
                std::string constituentDrvPath = jobs[childJobName]["drvPath"];
                job["constituents"].push_back(constituentDrvPath);
            }
        } else {
            auto drvPath = store->parseStorePath((std::string) job["drvPath"]);
            auto drv = store->readDerivation(drvPath);

            for (auto & childJobName : aggregateJob.dependencies) {
                auto childDrvPath = store->parseStorePath((std::string) jobs[childJobName]["drvPath"]);
                auto childDrv = store->readDerivation(childDrvPath);
                job["constituents"].push_back(store->printStorePath(childDrvPath));
                drv.inputDrvs.map[childDrvPath].value = {childDrv.outputs.begin()->first};
            }

            if (aggregateJob.brokenJobs.empty()) {
                std::string drvName(drvPath.name());
                assert(hasSuffix(drvName, drvExtension));
                drvName.resize(drvName.size() - drvExtension.size());

                auto hashModulo = hashDerivationModulo(*store, drv, true);
                if (hashModulo.kind != DrvHash::Kind::Regular) continue;
                auto h = hashModulo.hashes.find("out");
                if (h == hashModulo.hashes.end()) continue;
                auto outPath = store->makeOutputPath("out", h->second, drvName);
                drv.env["out"] = store->printStorePath(outPath);
                drv.outputs.insert_or_assign("out", DerivationOutput::InputAddressed { .path = outPath });
                auto newDrvPath = store->printStorePath(writeDerivation(*store, drv));

                debug("rewrote aggregate derivation %s -> %s", store->printStorePath(drvPath), newDrvPath);

                job["drvPath"] = newDrvPath;
                job["outputs"]["out"] = store->printStorePath(outPath);
            }
        }

        job.erase("namedConstituents");

        /* Register the derivation as a GC root.  !!! This
            registers roots for jobs that we may have already
            done. */
        auto localStore = store.dynamic_pointer_cast<LocalFSStore>();
        if (gcRootsDir != "" && localStore) {
            auto drvPath = job["drvPath"].get<std::string>();
            Path root = gcRootsDir + "/" + std::string(baseNameOf(drvPath));
            if (!pathExists(root))
                localStore->addPermRoot(localStore->parseStorePath(drvPath), root);
        }

        if (!aggregateJob.brokenJobs.empty()) {
            std::stringstream ss;
            for (const auto& [jobName, error] : aggregateJob.brokenJobs) {
                ss << jobName << ": " << error << "\n";
            }
            job["error"] = ss.str();
        }
    }
}

int main(int argc, char * * argv)
{
    /* Prevent undeclared dependencies in the evaluation via
       $NIX_PATH. */
    unsetenv("NIX_PATH");

    return handleExceptions(argv[0], [&]() {

        auto config = std::make_unique<HydraConfig>();

        auto nrWorkers = config->getIntOption("evaluator_workers", 1);
        maxMemorySize = config->getIntOption("evaluator_max_memory_size", 4096);

        initNix();
        initGC();

        myArgs.parseCmdline(argvToStrings(argc, argv));

        auto pureEval = config->getBoolOption("evaluator_pure_eval", myArgs.flake);

        /* FIXME: The build hook in conjunction with import-from-derivation is causing "unexpected EOF" during eval */
        settings.builders = "";

        /* Prevent access to paths outside of the Nix search path and
           to the environment. */
        evalSettings.restrictEval = true;

        /* When building a flake, use pure evaluation (no access to
           'getEnv', 'currentSystem' etc. */
        evalSettings.pureEval = pureEval;

        if (myArgs.dryRun) settings.readOnlyMode = true;

        if (myArgs.releaseExpr == "") throw UsageError("no expression specified");

        if (gcRootsDir == "") printMsg(lvlError, "warning: `--gc-roots-dir' not specified");

        struct State
        {
            std::set<std::string> todo{""};
            std::set<std::string> active;
            nlohmann::json jobs;
            std::exception_ptr exc;
        };

        std::condition_variable wakeup;

        Sync<State> state_;

        /* Start a handler thread per worker process. */
        auto handler = [&]()
        {
            pid_t pid = -1;
            try {
                AutoCloseFD from, to;

                while (true) {

                    /* Start a new worker process if necessary. */
                    if (pid == -1) {
                        Pipe toPipe, fromPipe;
                        toPipe.create();
                        fromPipe.create();
                        pid = startProcess(
                            [&,
                             to{std::make_shared<AutoCloseFD>(std::move(fromPipe.writeSide))},
                             from{std::make_shared<AutoCloseFD>(std::move(toPipe.readSide))}
                            ]()
                            {
                                try {
                                    auto evalStore = myArgs.evalStoreUrl
                                             ? openStore(*myArgs.evalStoreUrl)
                                             : openStore();
                                    EvalState state(myArgs.lookupPath,
                                            evalStore, fetchSettings, evalSettings);
                                    Bindings & autoArgs = *myArgs.getAutoArgs(state);
                                    worker(state, autoArgs, *to, *from);
                                } catch (Error & e) {
                                    nlohmann::json err;
                                    auto msg = e.msg();
                                    err["error"] = filterANSIEscapes(msg, true);
                                    printError(msg);
                                    writeLine(to->get(), err.dump());
                                    // Don't forget to print it into the STDERR log, this is
                                    // what's shown in the Hydra UI.
                                    writeLine(to->get(), "restart");
                                }
                            },
                            ProcessOptions { .allowVfork = false });
                        from = std::move(fromPipe.readSide);
                        to = std::move(toPipe.writeSide);
                        debug("created worker process %d", pid);
                    }

                    /* Check whether the existing worker process is still there. */
                    auto s = readLine(from.get());
                    if (s == "restart") {
                        pid = -1;
                        continue;
                    } else if (s != "next") {
                        auto json = nlohmann::json::parse(s);
                        throw Error("worker error: %s", (std::string) json["error"]);
                    }

                    /* Wait for a job name to become available. */
                    std::string attrPath;

                    while (true) {
                        checkInterrupt();
                        auto state(state_.lock());
                        if ((state->todo.empty() && state->active.empty()) || state->exc) {
                            writeLine(to.get(), "exit");
                            return;
                        }
                        if (!state->todo.empty()) {
                            attrPath = *state->todo.begin();
                            state->todo.erase(state->todo.begin());
                            state->active.insert(attrPath);
                            break;
                        } else
                            state.wait(wakeup);
                    }

                    /* Tell the worker to evaluate it. */
                    writeLine(to.get(), "do " + attrPath);

                    /* Wait for the response. */
                    auto response = nlohmann::json::parse(readLine(from.get()));

                    /* Handle the response. */
                    StringSet newAttrs;

                    if (response.find("job") != response.end()) {
                        auto state(state_.lock());
                        state->jobs[attrPath] = response["job"];
                    }

                    if (response.find("attrs") != response.end()) {
                        for (auto & i : response["attrs"]) {
                            std::string path = i;
                            if (path.find(".") != std::string::npos){
                                path = "\"" + path  + "\"";
                            }
                            auto s = (attrPath.empty() ? "" : attrPath + ".") + (std::string) path;
                            newAttrs.insert(s);
                        }
                    }

                    if (response.find("error") != response.end()) {
                        auto state(state_.lock());
                        state->jobs[attrPath]["error"] = response["error"];
                    }

                    /* Add newly discovered job names to the queue. */
                    {
                        auto state(state_.lock());
                        state->active.erase(attrPath);
                        for (auto & s : newAttrs)
                            state->todo.insert(s);
                        wakeup.notify_all();
                    }
                }
            } catch (...) {
                check_pid_status_nonblocking(pid);
                auto state(state_.lock());
                state->exc = std::current_exception();
                wakeup.notify_all();
            }
        };

        std::vector<std::thread> threads;
        for (size_t i = 0; i < nrWorkers; i++)
            threads.emplace_back(std::thread(handler));

        for (auto & thread : threads)
            thread.join();

        auto state(state_.lock());

        if (state->exc)
            std::rethrow_exception(state->exc);

        /* For aggregate jobs that have named constituents
           (i.e. constituents that are a job name rather than a
           derivation), look up the referenced job and add it to the
           dependencies of the aggregate derivation. */
        auto store = openStore();

        try {
            auto namedConstituents = resolveNamedConstituents(state->jobs);
            rewriteAggregates(state->jobs, namedConstituents, myArgs.dryRun, store);
        } catch (DependencyCycle & e) {
            printError("Found dependency cycle between jobs '%s' and '%s'", e.a, e.b);
            state->jobs[e.a]["error"] = e.what();
            state->jobs[e.b]["error"] = e.what();

            for (auto & jobName : e.remainingAggregates) {
                state->jobs[jobName]["error"] = "Skipping aggregate because of a dependency cycle";
            }
        }

        std::cout << state->jobs.dump(2) << "\n";
    });
}

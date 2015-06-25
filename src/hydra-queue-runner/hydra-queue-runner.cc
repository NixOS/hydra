#include <atomic>
#include <condition_variable>
#include <iostream>
#include <map>
#include <queue>
#include <memory>
#include <thread>
#include <cmath>
#include <chrono>
#include <algorithm>

#include <pqxx/pqxx>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "build-result.hh"
#include "build-remote.hh"
#include "sync.hh"
#include "pool.hh"
#include "counter.hh"
#include "token-server.hh"

#include "store-api.hh"
#include "derivations.hh"
#include "shared.hh"
#include "globals.hh"
#include "value-to-json.hh"
#include "pathlocks.hh"

using namespace nix;


// FIXME: Make configurable.
const unsigned int maxTries = 5;
const unsigned int retryInterval = 60; // seconds
const float retryBackoff = 3.0;
const unsigned int maxParallelCopyClosure = 4;


typedef std::chrono::time_point<std::chrono::system_clock> system_time;


template <class C, class V>
bool has(const C & c, const V & v)
{
    return c.find(v) != c.end();
}


typedef enum {
    bsSuccess = 0,
    bsFailed = 1,
    bsDepFailed = 2,
    bsAborted = 3,
    bsFailedWithOutput = 6,
    bsTimedOut = 7,
    bsUnsupported = 9,
} BuildStatus;


typedef enum {
    bssSuccess = 0,
    bssFailed = 1,
    bssAborted = 4,
    bssTimedOut = 7,
    bssUnsupported = 9,
    bssBusy = 100, // not stored
} BuildStepStatus;


struct Connection : pqxx::connection
{
    Connection() : pqxx::connection(getFlags()) { };

    string getFlags()
    {
        string s = getEnv("HYDRA_DBI", "dbi:Pg:dbname=hydra;");
        string prefix = "dbi:Pg:";
        if (string(s, 0, prefix.size()) != prefix)
            throw Error("$HYDRA_DBI does not denote a PostgreSQL database");
        return concatStringsSep(" ", tokenizeString<Strings>(string(s, prefix.size()), ";"));
    }
};


struct receiver : public pqxx::notification_receiver
{
    bool status = false;
    receiver(pqxx::connection_base & c, const std::string & channel)
        : pqxx::notification_receiver(c, channel) { }
    void operator() (const string & payload, int pid) override
    {
        status = true;
    };
    bool get() {
        bool b = status;
        status = false;
        return b;
    }
};


typedef unsigned int BuildID;


struct Step;


struct Build
{
    typedef std::shared_ptr<Build> ptr;
    typedef std::weak_ptr<Build> wptr;

    BuildID id;
    Path drvPath;
    std::map<string, Path> outputs;
    std::string fullJobName;
    unsigned int maxSilentTime, buildTimeout;

    std::shared_ptr<Step> toplevel;

    std::atomic_bool finishedInDB{false};

    ~Build()
    {
        printMsg(lvlDebug, format("destroying build %1%") % id);
    }
};


struct Step
{
    typedef std::shared_ptr<Step> ptr;
    typedef std::weak_ptr<Step> wptr;

    Path drvPath;
    Derivation drv;
    std::set<std::string> requiredSystemFeatures;

    struct State
    {
        /* Whether the step has finished initialisation. */
        bool created = false;

        /* The build steps on which this step depends. */
        std::set<Step::ptr> deps;

        /* The build steps that depend on this step. */
        std::vector<Step::wptr> rdeps;

        /* Builds that have this step as the top-level derivation. */
        std::vector<Build::wptr> builds;

        /* Number of times we've tried this step. */
        unsigned int tries = 0;

        /* Point in time after which the step can be retried. */
        system_time after;
    };

    std::atomic_bool finished{false}; // debugging

    Sync<State> state;

    ~Step()
    {
        //printMsg(lvlError, format("destroying step %1%") % drvPath);
    }
};


struct Machine
{
    typedef std::shared_ptr<Machine> ptr;

    std::string sshName, sshKey;
    std::set<std::string> systemTypes, supportedFeatures, mandatoryFeatures;
    unsigned int maxJobs = 1;
    float speedFactor = 1.0;

    struct State {
        typedef std::shared_ptr<State> ptr;
        counter currentJobs{0};
        counter nrStepsDone{0};
        counter totalStepTime{0}; // total time for steps, including closure copying
        counter totalStepBuildTime{0}; // total build time for steps
    };

    State::ptr state;

    bool supportsStep(Step::ptr step)
    {
        if (systemTypes.find(step->drv.platform) == systemTypes.end()) return false;
        for (auto & f : mandatoryFeatures)
            if (step->requiredSystemFeatures.find(f) == step->requiredSystemFeatures.end()) return false;
        for (auto & f : step->requiredSystemFeatures)
            if (supportedFeatures.find(f) == supportedFeatures.end()) return false;
        return true;
    }
};


class State
{
private:

    Path hydraData, logDir;

    /* The queued builds. */
    typedef std::map<BuildID, Build::ptr> Builds;
    Sync<Builds> builds;

    /* All active or pending build steps (i.e. dependencies of the
       queued builds). Note that these are weak pointers. Steps are
       kept alive by being reachable from Builds or by being in
       progress. */
    typedef std::map<Path, Step::wptr> Steps;
    Sync<Steps> steps;

    /* Build steps that have no unbuilt dependencies. */
    typedef std::list<Step::wptr> Runnable;
    Sync<Runnable> runnable;

    /* CV for waking up the dispatcher. */
    std::condition_variable dispatcherWakeup;
    std::mutex dispatcherMutex;

    /* PostgreSQL connection pool. */
    Pool<Connection> dbPool;

    /* The build machines. */
    typedef std::map<string, Machine::ptr> Machines;
    Sync<Machines> machines; // FIXME: use atomic_shared_ptr

    Path machinesFile;
    struct stat machinesFileStat;

    /* Token server limiting the number of threads copying closures in
       parallel to prevent excessive I/O load. */
    TokenServer copyClosureTokenServer{maxParallelCopyClosure};

    /* Various stats. */
    time_t startedAt;
    counter nrBuildsRead{0};
    counter nrBuildsDone{0};
    counter nrStepsDone{0};
    counter nrActiveSteps{0};
    counter nrStepsBuilding{0};
    counter nrStepsCopyingTo{0};
    counter nrStepsCopyingFrom{0};
    counter nrRetries{0};
    counter maxNrRetries{0};
    counter totalStepTime{0}; // total time for steps, including closure copying
    counter totalStepBuildTime{0}; // total build time for steps
    counter nrQueueWakeups{0};
    counter nrDispatcherWakeups{0};
    counter bytesSent{0};
    counter bytesReceived{0};

    /* Log compressor work queue. */
    Sync<std::queue<Path>> logCompressorQueue;
    std::condition_variable_any logCompressorWakeup;

    /* Notification sender work queue. FIXME: if hydra-queue-runner is
       killed before it has finished sending notifications about a
       build, then the notifications may be lost. It would be better
       to mark builds with pending notification in the database. */
    typedef std::pair<BuildID, std::vector<BuildID>> NotificationItem;
    Sync<std::queue<NotificationItem>> notificationSenderQueue;
    std::condition_variable_any notificationSenderWakeup;

    /* Specific build to do for --build-one (testing only). */
    BuildID buildOne;

public:
    State();

private:

    void clearBusy(Connection & conn, time_t stopTime);

    /* (Re)load /etc/nix/machines. */
    void loadMachinesFile();

    /* Thread to reload /etc/nix/machines periodically. */
    void monitorMachinesFile();

    int createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
        const std::string & machine, BuildStepStatus status, const std::string & errorMsg = "",
        BuildID propagatedFrom = 0);

    void finishBuildStep(pqxx::work & txn, time_t startTime, time_t stopTime, BuildID buildId, int stepNr,
        const std::string & machine, BuildStepStatus status, const string & errorMsg = "",
        BuildID propagatedFrom = 0);

    void updateBuild(pqxx::work & txn, Build::ptr build, BuildStatus status);

    void queueMonitor();

    void queueMonitorLoop();

    void getQueuedBuilds(Connection & conn, std::shared_ptr<StoreAPI> store, unsigned int & lastBuildId);

    void removeCancelledBuilds(Connection & conn);

    Step::ptr createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath,
        Build::ptr referringBuild, Step::ptr referringStep, std::set<Path> & finishedDrvs,
        std::set<Step::ptr> & newSteps, std::set<Step::ptr> & newRunnable);

    void makeRunnable(Step::ptr step);

    /* The thread that selects and starts runnable builds. */
    void dispatcher();

    void wakeDispatcher();

    void builder(Step::ptr step, Machine::ptr machine, std::shared_ptr<MaintainCount> reservation);

    /* Perform the given build step. Return true if the step is to be
       retried. */
    bool doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step,
        Machine::ptr machine);

    void markSucceededBuild(pqxx::work & txn, Build::ptr build,
        const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime);

    bool checkCachedFailure(Step::ptr step, Connection & conn);

    /* Thread that asynchronously bzips logs of finished steps. */
    void logCompressor();

    /* Thread that asynchronously invokes hydra-notify to send build
       notifications. */
    void notificationSender();

    /* Acquire the global queue runner lock, or null if somebody else
       has it. */
    std::shared_ptr<PathLocks> acquireGlobalLock();

    void dumpStatus(Connection & conn, bool log);

public:

    void showStatus();

    void unlock();

    void run(BuildID buildOne = 0);
};


State::State()
{
    hydraData = getEnv("HYDRA_DATA");
    if (hydraData == "") throw Error("$HYDRA_DATA must be set");

    logDir = canonPath(hydraData + "/build-logs");

    machinesFile = getEnv("NIX_REMOTE_SYSTEMS", "/etc/nix/machines");
    machinesFileStat.st_ino = 0;
    machinesFileStat.st_mtime = 0;
}


void State::loadMachinesFile()
{
    string contents;
    if (pathExists(machinesFile)) {
        struct stat st;
        if (stat(machinesFile.c_str(), &st) != 0)
            throw SysError(format("getting stats about ‘%1%’") % machinesFile);
        if (st.st_ino == machinesFileStat.st_ino && st.st_mtime == machinesFileStat.st_mtime)
            return;
        printMsg(lvlDebug, "reloading machines");
        contents = readFile(machinesFile);
        machinesFileStat = st;
    } else {
        StringSet systems = StringSet({settings.thisSystem});
        if (settings.thisSystem == "x86_64-linux")
            systems.insert("i686-linux");
        contents = "localhost " + concatStringsSep(",", systems)
            + " - " + int2String(settings.maxBuildJobs) + " 1";
    }

    Machines newMachines, oldMachines;
    {
        auto machines_(machines.lock());
        oldMachines = *machines_;
    }

    for (auto line : tokenizeString<Strings>(contents, "\n")) {
        line = trim(string(line, 0, line.find('#')));
        auto tokens = tokenizeString<std::vector<std::string>>(line);
        if (tokens.size() < 3) continue;
        tokens.resize(7);

        auto machine = std::make_shared<Machine>();
        machine->sshName = tokens[0];
        machine->systemTypes = tokenizeString<StringSet>(tokens[1], ",");
        machine->sshKey = tokens[2];
        if (tokens[3] != "")
            string2Int(tokens[3], machine->maxJobs);
        else
            machine->maxJobs = 1;
        machine->speedFactor = atof(tokens[4].c_str());
        machine->supportedFeatures = tokenizeString<StringSet>(tokens[5], ",");
        machine->mandatoryFeatures = tokenizeString<StringSet>(tokens[6], ",");
        for (auto & f : machine->mandatoryFeatures)
            machine->supportedFeatures.insert(f);

        /* Re-use the State object of the previous machine with the
           same name. */
        auto i = oldMachines.find(machine->sshName);
        if (i == oldMachines.end())
            printMsg(lvlChatty, format("adding new machine ‘%1%’") % machine->sshName);
        else
            printMsg(lvlChatty, format("updating machine ‘%1%’") % machine->sshName);
        machine->state = i == oldMachines.end()
            ? std::make_shared<Machine::State>()
            : i->second->state;
        newMachines[machine->sshName] = machine;
    }

    for (auto & m : oldMachines)
        if (newMachines.find(m.first) == newMachines.end())
            printMsg(lvlInfo, format("removing machine ‘%1%’") % m.first);

    auto machines_(machines.lock());
    *machines_ = newMachines;
}


void State::monitorMachinesFile()
{
    while (true) {
        try {
            // FIXME: use inotify.
            sleep(60);
            loadMachinesFile();
        } catch (std::exception & e) {
            printMsg(lvlError, format("reloading machines file: %1%") % e.what());
        }
    }
}


void State::clearBusy(Connection & conn, time_t stopTime)
{
    pqxx::work txn(conn);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, stopTime = $2 where busy = 1")
        ((int) bssAborted)
        (stopTime, stopTime != 0).exec();
    txn.exec("update Builds set busy = 0 where finished = 0 and busy = 1");
    txn.commit();
}


int State::createBuildStep(pqxx::work & txn, time_t startTime, Build::ptr build, Step::ptr step,
    const std::string & machine, BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    /* Acquire an exclusive lock on BuildSteps to ensure that we don't
       race with other threads creating a step of the same build. */
    txn.exec("lock table BuildSteps in exclusive mode");

    auto res = txn.parameterized("select max(stepnr) from BuildSteps where build = $1")(build->id).exec();
    int stepNr = res[0][0].is_null() ? 1 : res[0][0].as<int>() + 1;

    txn.parameterized
        ("insert into BuildSteps (build, stepnr, type, drvPath, busy, startTime, system, status, propagatedFrom, errorMsg, stopTime, machine) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)")
        (build->id)(stepNr)(0)(step->drvPath)(status == bssBusy ? 1 : 0)
        (startTime, startTime != 0)
        (step->drv.platform)
        ((int) status, status != bssBusy)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (startTime, startTime != 0 && status != bssBusy)
        (machine).exec();

    for (auto & output : step->drv.outputs)
        txn.parameterized
            ("insert into BuildStepOutputs (build, stepnr, name, path) values ($1, $2, $3, $4)")
            (build->id)(stepNr)(output.first)(output.second.path).exec();

    return stepNr;
}


void State::finishBuildStep(pqxx::work & txn, time_t startTime, time_t stopTime, BuildID buildId, int stepNr,
    const std::string & machine, BuildStepStatus status, const std::string & errorMsg, BuildID propagatedFrom)
{
    assert(startTime);
    assert(stopTime);
    txn.parameterized
        ("update BuildSteps set busy = 0, status = $1, propagatedFrom = $4, errorMsg = $5, startTime = $6, stopTime = $7, machine = $8 where build = $2 and stepnr = $3")
        ((int) status)(buildId)(stepNr)
        (propagatedFrom, propagatedFrom != 0)
        (errorMsg, errorMsg != "")
        (startTime)(stopTime)
        (machine, machine != "").exec();
}


void State::queueMonitor()
{
    while (true) {
        try {
            queueMonitorLoop();
        } catch (std::exception & e) {
            printMsg(lvlError, format("queue monitor: %1%") % e.what());
            sleep(10); // probably a DB problem, so don't retry right away
        }
    }
}


void State::queueMonitorLoop()
{
    auto conn(dbPool.get());

    receiver buildsAdded(*conn, "builds_added");
    receiver buildsRestarted(*conn, "builds_restarted");
    receiver buildsCancelled(*conn, "builds_cancelled");

    auto store = openStore(); // FIXME: pool

    unsigned int lastBuildId = 0;

    while (true) {
        getQueuedBuilds(*conn, store, lastBuildId);

        /* Sleep until we get notification from the database about an
           event. */
        conn->await_notification();
        nrQueueWakeups++;

        if (buildsAdded.get())
            printMsg(lvlTalkative, "got notification: new builds added to the queue");
        if (buildsRestarted.get()) {
            printMsg(lvlTalkative, "got notification: builds restarted");
            lastBuildId = 0; // check all builds
        }
        if (buildsCancelled.get()) {
            printMsg(lvlTalkative, "got notification: builds cancelled");
            removeCancelledBuilds(*conn);
        }

    }
}


void State::getQueuedBuilds(Connection & conn, std::shared_ptr<StoreAPI> store, unsigned int & lastBuildId)
{
    printMsg(lvlInfo, format("checking the queue for builds > %1%...") % lastBuildId);

    /* Grab the queued builds from the database, but don't process
       them yet (since we don't want a long-running transaction). */
    std::multimap<Path, Build::ptr> newBuilds;

    {
        pqxx::work txn(conn);

        auto res = txn.parameterized("select id, project, jobset, job, drvPath, maxsilent, timeout from Builds where id > $1 and finished = 0 order by id")(lastBuildId).exec();

        for (auto const & row : res) {
            auto builds_(builds.lock());
            BuildID id = row["id"].as<BuildID>();
            if (buildOne && id != buildOne) continue;
            if (id > lastBuildId) lastBuildId = id;
            if (has(*builds_, id)) continue;

            auto build = std::make_shared<Build>();
            build->id = id;
            build->drvPath = row["drvPath"].as<string>();
            build->fullJobName = row["project"].as<string>() + ":" + row["jobset"].as<string>() + ":" + row["job"].as<string>();
            build->maxSilentTime = row["maxsilent"].as<int>();
            build->buildTimeout = row["timeout"].as<int>();

            newBuilds.emplace(std::make_pair(build->drvPath, build));
        }
    }

    std::set<Step::ptr> newRunnable;
    unsigned int nrAdded;
    std::function<void(Build::ptr)> createBuild;

    createBuild = [&](Build::ptr build) {
        printMsg(lvlTalkative, format("loading build %1% (%2%)") % build->id % build->fullJobName);
        nrAdded++;

        if (!store->isValidPath(build->drvPath)) {
            /* Derivation has been GC'ed prematurely. */
            printMsg(lvlError, format("aborting GC'ed build %1%") % build->id);
            if (!build->finishedInDB) {
                pqxx::work txn(conn);
                txn.parameterized
                    ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $3, errorMsg = $4 where id = $1 and finished = 0")
                    (build->id)
                    ((int) bsAborted)
                    (time(0))
                    ("derivation was garbage-collected prior to build").exec();
                txn.commit();
                build->finishedInDB = true;
                nrBuildsDone++;
            }
            return;
        }

        std::set<Step::ptr> newSteps;
        std::set<Path> finishedDrvs; // FIXME: re-use?
        Step::ptr step = createStep(store, build->drvPath, build, 0, finishedDrvs, newSteps, newRunnable);

        /* Some of the new steps may be the top level of builds that
           we haven't processed yet. So do them now. This ensures that
           if build A depends on build B with top-level step X, then X
           will be "accounted" to B in doBuildStep(). */
        for (auto & r : newSteps) {
            while (true) {
                auto i = newBuilds.find(r->drvPath);
                if (i == newBuilds.end()) break;
                Build::ptr b = i->second;
                newBuilds.erase(i);
                createBuild(b);
            }
        }

        /* If we didn't get a step, it means the step's outputs are
           all valid. So we mark this as a finished, cached build. */
        if (!step) {
            Derivation drv = readDerivation(build->drvPath);
            BuildResult res = getBuildResult(store, drv);

            pqxx::work txn(conn);
            time_t now = time(0);
            markSucceededBuild(txn, build, res, true, now, now);
            txn.commit();

            build->finishedInDB = true;

            return;
        }

        /* If any step has an unsupported system type or has a
           previously failed output path, then fail the build right
           away. */
        bool badStep = false;
        for (auto & r : newSteps) {
            BuildStatus buildStatus = bsSuccess;
            BuildStepStatus buildStepStatus = bssFailed;

            if (checkCachedFailure(r, conn)) {
                printMsg(lvlError, format("marking build %1% as cached failure") % build->id);
                buildStatus = step == r ? bsFailed : bsDepFailed;
                buildStepStatus = bssFailed;
            }

            if (buildStatus == bsSuccess) {
                bool supported = false;
                {
                    auto machines_(machines.lock()); // FIXME: use shared_mutex
                    for (auto & m : *machines_)
                        if (m.second->supportsStep(r)) { supported = true; break; }
                }

                if (!supported) {
                    printMsg(lvlError, format("aborting unsupported build %1%") % build->id);
                    buildStatus = bsUnsupported;
                    buildStepStatus = bssUnsupported;
                }
            }

            if (buildStatus != bsSuccess) {
                time_t now = time(0);
                if (!build->finishedInDB) {
                    pqxx::work txn(conn);
                    createBuildStep(txn, 0, build, r, "", buildStepStatus);
                    txn.parameterized
                        ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $3, isCachedBuild = $4 where id = $1 and finished = 0")
                        (build->id)
                        ((int) buildStatus)
                        (now)
                        (buildStatus != bsUnsupported ? 1 : 0).exec();
                    txn.commit();
                    build->finishedInDB = true;
                    nrBuildsDone++;
                }
                badStep = true;
                break;
            }
        }

        if (badStep) return;

        /* Note: if we exit this scope prior to this, the build and
           all newly created steps are destroyed. */

        {
            auto builds_(builds.lock());
            if (!build->finishedInDB) // FIXME: can this happen?
                (*builds_)[build->id] = build;
            build->toplevel = step;
        }

        printMsg(lvlChatty, format("added build %1% (top-level step %2%, %3% new steps)")
            % build->id % step->drvPath % newSteps.size());
    };

    /* Now instantiate build steps for each new build. The builder
       threads can start building the runnable build steps right away,
       even while we're still processing other new builds. */
    while (!newBuilds.empty()) {
        auto build = newBuilds.begin()->second;
        newBuilds.erase(newBuilds.begin());

        newRunnable.clear();
        nrAdded = 0;
        try {
            createBuild(build);
        } catch (Error & e) {
            printMsg(lvlError, format("while loading build %1%: %2%") % build->id % e.what());
            continue; // FIXME: retry later?
        }

        /* Add the new runnable build steps to ‘runnable’ and wake up
           the builder threads. */
        printMsg(lvlChatty, format("got %1% new runnable steps from %2% new builds") % newRunnable.size() % nrAdded);
        for (auto & r : newRunnable)
            makeRunnable(r);

        nrBuildsRead += nrAdded;
    }
}


void State::removeCancelledBuilds(Connection & conn)
{
    /* Get the current set of queued builds. */
    std::set<BuildID> currentIds;
    {
        pqxx::work txn(conn);
        auto res = txn.exec("select id from Builds where finished = 0");
        for (auto const & row : res)
            currentIds.insert(row["id"].as<BuildID>());
    }

    auto builds_(builds.lock());

    for (auto i = builds_->begin(); i != builds_->end(); ) {
        if (currentIds.find(i->first) == currentIds.end()) {
            printMsg(lvlInfo, format("discarding cancelled build %1%") % i->first);
            i = builds_->erase(i);
            // FIXME: ideally we would interrupt active build steps here.
        } else
            ++i;
    }
}


Step::ptr State::createStep(std::shared_ptr<StoreAPI> store, const Path & drvPath,
    Build::ptr referringBuild, Step::ptr referringStep, std::set<Path> & finishedDrvs,
    std::set<Step::ptr> & newSteps, std::set<Step::ptr> & newRunnable)
{
    if (finishedDrvs.find(drvPath) != finishedDrvs.end()) return 0;

    /* Check if the requested step already exists. If not, create a
       new step. In any case, make the step reachable from
       referringBuild or referringStep. This is done atomically (with
       ‘steps’ locked), to ensure that this step can never become
       reachable from a new build after doBuildStep has removed it
       from ‘steps’. */
    Step::ptr step;
    bool isNew = false;
    {
        auto steps_(steps.lock());

        /* See if the step already exists in ‘steps’ and is not
           stale. */
        auto prev = steps_->find(drvPath);
        if (prev != steps_->end()) {
            step = prev->second.lock();
            /* Since ‘step’ is a strong pointer, the referred Step
               object won't be deleted after this. */
            if (!step) steps_->erase(drvPath); // remove stale entry
        }

        /* If it doesn't exist, create it. */
        if (!step) {
            step = std::make_shared<Step>();
            step->drvPath = drvPath;
            isNew = true;
        }

        auto step_(step->state.lock());

        assert(step_->created != isNew);

        if (referringBuild)
            step_->builds.push_back(referringBuild);

        if (referringStep)
            step_->rdeps.push_back(referringStep);

        (*steps_)[drvPath] = step;
    }

    if (!isNew) return step;

    printMsg(lvlDebug, format("considering derivation ‘%1%’") % drvPath);

    /* Initialize the step. Note that the step may be visible in
       ‘steps’ before this point, but that doesn't matter because
       it's not runnable yet, and other threads won't make it
       runnable while step->created == false. */
    step->drv = readDerivation(drvPath);
    {
        auto i = step->drv.env.find("requiredSystemFeatures");
        if (i != step->drv.env.end())
            step->requiredSystemFeatures = tokenizeString<std::set<std::string>>(i->second);
    }

    /* Are all outputs valid? */
    bool valid = true;
    for (auto & i : step->drv.outputs) {
        if (!store->isValidPath(i.second.path)) {
            valid = false;
            break;
        }
    }

    // FIXME: check whether all outputs are in the binary cache.
    if (valid) {
        finishedDrvs.insert(drvPath);
        return 0;
    }

    /* No, we need to build. */
    printMsg(lvlDebug, format("creating build step ‘%1%’") % drvPath);
    newSteps.insert(step);

    /* Create steps for the dependencies. */
    for (auto & i : step->drv.inputDrvs) {
        auto dep = createStep(store, i.first, 0, step, finishedDrvs, newSteps, newRunnable);
        if (dep) {
            auto step_(step->state.lock());
            step_->deps.insert(dep);
        }
    }

    /* If the step has no (remaining) dependencies, make it
       runnable. */
    {
        auto step_(step->state.lock());
        assert(!step_->created);
        step_->created = true;
        if (step_->deps.empty())
            newRunnable.insert(step);
    }

    return step;
}


/* Get the steps and unfinished builds that depend on the given step. */
void getDependents(Step::ptr step, std::set<Build::ptr> & builds, std::set<Step::ptr> & steps)
{
    std::function<void(Step::ptr)> visit;

    visit = [&](Step::ptr step) {
        if (has(steps, step)) return;
        steps.insert(step);

        std::vector<Step::wptr> rdeps;

        {
            auto step_(step->state.lock());

            for (auto & build : step_->builds) {
                auto build_ = build.lock();
                if (build_ && !build_->finishedInDB) builds.insert(build_);
            }

            /* Make a copy of rdeps so that we don't hold the lock for
               very long. */
            rdeps = step_->rdeps;
        }

        for (auto & rdep : rdeps) {
            auto rdep_ = rdep.lock();
            if (rdep_) visit(rdep_);
        }
    };

    visit(step);
}


void State::makeRunnable(Step::ptr step)
{
    printMsg(lvlChatty, format("step ‘%1%’ is now runnable") % step->drvPath);

    {
        auto step_(step->state.lock());
        assert(step_->created);
        assert(!step->finished);
        assert(step_->deps.empty());
    }

    {
        auto runnable_(runnable.lock());
        runnable_->push_back(step);
    }

    wakeDispatcher();
}


void State::dispatcher()
{
    while (true) {
        printMsg(lvlDebug, "dispatcher woken up");

        auto sleepUntil = system_time::max();

        bool keepGoing;

        do {
            /* Copy the currentJobs field of each machine. This is
               necessary to ensure that the sort comparator below is
               an ordering. std::sort() can segfault if it isn't. */
            struct MachineInfo
            {
                Machine::ptr machine;
                unsigned int currentJobs;
            };
            std::vector<MachineInfo> machinesSorted;
            {
                auto machines_(machines.lock());
                for (auto & m : *machines_)
                    machinesSorted.push_back({m.second, m.second->state->currentJobs});
            }

            /* Sort the machines by a combination of speed factor and
               available slots. Prioritise the available machines as
               follows:

               - First by load divided by speed factor, rounded to the
                 nearest integer.  This causes fast machines to be
                 preferred over slow machines with similar loads.

               - Then by speed factor.

               - Finally by load. */
            sort(machinesSorted.begin(), machinesSorted.end(),
                [](const MachineInfo & a, const MachineInfo & b) -> bool
                {
                    float ta = roundf(a.currentJobs / a.machine->speedFactor);
                    float tb = roundf(b.currentJobs / b.machine->speedFactor);
                    return
                        ta != tb ? ta < tb :
                        a.machine->speedFactor != b.machine->speedFactor ? a.machine->speedFactor > b.machine->speedFactor :
                        a.currentJobs > b.currentJobs;
                });

            /* Find a machine with a free slot and find a step to run
               on it. Once we find such a pair, we restart the outer
               loop because the machine sorting will have changed. */
            keepGoing = false;
            system_time now = std::chrono::system_clock::now();

            for (auto & mi : machinesSorted) {
                // FIXME: can we lose a wakeup if a builder exits concurrently?
                if (mi.machine->state->currentJobs >= mi.machine->maxJobs) continue;

                auto runnable_(runnable.lock());
                //printMsg(lvlDebug, format("%1% runnable builds") % runnable_->size());

                /* FIXME: we're holding the runnable lock too long
                   here. This could be more efficient. */

                for (auto i = runnable_->begin(); i != runnable_->end(); ) {
                    auto step = i->lock();

                    /* Delete dead steps. */
                    if (!step) {
                        i = runnable_->erase(i);
                        continue;
                    }

                    /* Can this machine do this step? */
                    if (!mi.machine->supportsStep(step)) {
                        ++i;
                        continue;
                    }

                    /* Skip previously failed steps that aren't ready
                       to be retried. */
                    {
                        auto step_(step->state.lock());
                        if (step_->tries > 0 && step_->after > now) {
                            if (step_->after < sleepUntil)
                                sleepUntil = step_->after;
                            ++i;
                            continue;
                        }
                    }

                    /* Make a slot reservation and start a thread to
                       do the build. */
                    auto reservation = std::make_shared<MaintainCount>(mi.machine->state->currentJobs);
                    i = runnable_->erase(i);

                    auto builderThread = std::thread(&State::builder, this, step, mi.machine, reservation);
                    builderThread.detach(); // FIXME?

                    keepGoing = true;
                    break;
                }

                if (keepGoing) break;
            }

        } while (keepGoing);

        /* Sleep until we're woken up (either because a runnable build
           is added, or because a build finishes). */
        {
            std::unique_lock<std::mutex> lock(dispatcherMutex);
            printMsg(lvlDebug, format("dispatcher sleeping for %1%s") %
                std::chrono::duration_cast<std::chrono::seconds>(sleepUntil - std::chrono::system_clock::now()).count());
            dispatcherWakeup.wait_until(lock, sleepUntil);
            nrDispatcherWakeups++;
        }
    }

    printMsg(lvlError, "dispatcher exits");
}


void State::wakeDispatcher()
{
    { std::lock_guard<std::mutex> lock(dispatcherMutex); } // barrier
    dispatcherWakeup.notify_one();
}


void State::builder(Step::ptr step, Machine::ptr machine, std::shared_ptr<MaintainCount> reservation)
{
    bool retry = true;

    MaintainCount mc(nrActiveSteps);

    try {
        auto store = openStore(); // FIXME: pool
        retry = doBuildStep(store, step, machine);
    } catch (std::exception & e) {
        printMsg(lvlError, format("uncaught exception building ‘%1%’ on ‘%2%’: %3%")
            % step->drvPath % machine->sshName % e.what());
    }

    /* Release the machine and wake up the dispatcher. */
    assert(reservation.unique());
    reservation = 0;
    wakeDispatcher();

    /* If there was a temporary failure, retry the step after an
       exponentially increasing interval. */
    if (retry) {
        {
            auto step_(step->state.lock());
            step_->tries++;
            nrRetries++;
            if (step_->tries > maxNrRetries) maxNrRetries = step_->tries; // yeah yeah, not atomic
            int delta = retryInterval * powf(retryBackoff, step_->tries - 1);
            printMsg(lvlInfo, format("will retry ‘%1%’ after %2%s") % step->drvPath % delta);
            step_->after = std::chrono::system_clock::now() + std::chrono::seconds(delta);
        }

        makeRunnable(step);
    }
}


bool State::doBuildStep(std::shared_ptr<StoreAPI> store, Step::ptr step,
    Machine::ptr machine)
{
    {
        auto step_(step->state.lock());
        assert(step_->created);
        assert(!step->finished);
    }

    /* There can be any number of builds in the database that depend
       on this derivation. Arbitrarily pick one (though preferring a
       build of which this is the top-level derivation) for the
       purpose of creating build steps. We could create a build step
       record for every build, but that could be very expensive
       (e.g. a stdenv derivation can be a dependency of tens of
       thousands of builds), so we don't. */
    Build::ptr build;

    {
        std::set<Build::ptr> dependents;
        std::set<Step::ptr> steps;
        getDependents(step, dependents, steps);

        if (dependents.empty()) {
            /* Apparently all builds that depend on this derivation
               are gone (e.g. cancelled). So don't bother. This is
               very unlikely to happen, because normally Steps are
               only kept alive by being reachable from a
               Build. However, it's possible that a new Build just
               created a reference to this step. So to handle that
               possibility, we retry this step (putting it back in
               the runnable queue). If there are really no strong
               pointers to the step, it will be deleted. */
            printMsg(lvlInfo, format("maybe cancelling build step ‘%1%’") % step->drvPath);
            return true;
        }

        for (auto build2 : dependents)
            if (build2->drvPath == step->drvPath) { build = build2; break; }

        if (!build) build = *dependents.begin();

        printMsg(lvlInfo, format("performing step ‘%1%’ on ‘%2%’ (needed by build %3% and %4% others)")
            % step->drvPath % machine->sshName % build->id % (dependents.size() - 1));
    }

    bool quit = build->id == buildOne;

    auto conn(dbPool.get());

    RemoteResult result;
    BuildResult res;
    int stepNr = 0;

    time_t stepStartTime = result.startTime = time(0);

    /* If any of the outputs have previously failed, then don't bother
       building again. */
    bool cachedFailure = checkCachedFailure(step, *conn);

    if (cachedFailure)
        result.status = RemoteResult::rrPermanentFailure;
    else {

        /* Create a build step record indicating that we started
           building. Also, mark the selected build as busy. */
        {
            pqxx::work txn(*conn);
            stepNr = createBuildStep(txn, result.startTime, build, step, machine->sshName, bssBusy);
            txn.parameterized("update Builds set busy = 1 where id = $1")(build->id).exec();
            txn.commit();
        }

        /* Do the build. */
        try {
            /* FIXME: referring builds may have conflicting timeouts. */
            buildRemote(store, machine->sshName, machine->sshKey, step->drvPath, step->drv,
                logDir, build->maxSilentTime, build->buildTimeout, copyClosureTokenServer,
                result, nrStepsBuilding, nrStepsCopyingTo, nrStepsCopyingFrom,
                bytesSent, bytesReceived);
        } catch (Error & e) {
            result.status = RemoteResult::rrMiscFailure;
            result.errorMsg = e.msg();
        }

        if (result.status == RemoteResult::rrSuccess) res = getBuildResult(store, step->drv);
    }

    time_t stepStopTime = time(0);
    if (!result.stopTime) result.stopTime = stepStopTime;

    /* Asynchronously compress the log. */
    if (result.logFile != "") {
        {
            auto logCompressorQueue_(logCompressorQueue.lock());
            logCompressorQueue_->push(result.logFile);
        }
        logCompressorWakeup.notify_one();
    }

    /* The step had a hopefully temporary failure (e.g. network
       issue). Retry a number of times. */
    if (result.status == RemoteResult::rrMiscFailure) {
        printMsg(lvlError, format("irregular failure building ‘%1%’ on ‘%2%’: %3%")
            % step->drvPath % machine->sshName % result.errorMsg);
        bool retry;
        {
            auto step_(step->state.lock());
            retry = step_->tries + 1 < maxTries;
        }
        if (retry) {
            pqxx::work txn(*conn);
            finishBuildStep(txn, result.startTime, result.stopTime, build->id,
                stepNr, machine->sshName, bssAborted, result.errorMsg);
            txn.commit();
            if (quit) exit(1);
            return true;
        }
    }

    if (result.status == RemoteResult::rrSuccess) {

        /* Register success in the database for all Build objects that
           have this step as the top-level step. Since the queue
           monitor thread may be creating new referring Builds
           concurrently, and updating the database may fail, we do
           this in a loop, marking all known builds, repeating until
           there are no unmarked builds.
        */

        std::vector<BuildID> buildIDs;

        while (true) {

            /* Get the builds that have this one as the top-level. */
            std::vector<Build::ptr> direct;
            {
                auto steps_(steps.lock());
                auto step_(step->state.lock());

                for (auto & b_ : step_->builds) {
                    auto b = b_.lock();
                    if (b && !b->finishedInDB) direct.push_back(b);
                }

                /* If there are no builds left to update in the DB,
                   then we're done (except for calling
                   finishBuildStep()). Delete the step from
                   ‘steps’. Since we've been holding the ‘steps’ lock,
                   no new referrers can have been added in the
                   meantime or be added afterwards. */
                if (direct.empty()) {
                    printMsg(lvlDebug, format("finishing build step ‘%1%’") % step->drvPath);
                    steps_->erase(step->drvPath);
                }
            }

            /* Update the database. */
            {
                pqxx::work txn(*conn);

                finishBuildStep(txn, result.startTime, result.stopTime, build->id, stepNr, machine->sshName, bssSuccess);

                for (auto & b : direct)
                    markSucceededBuild(txn, b, res, build != b,
                        result.startTime, result.stopTime);

                txn.commit();
            }

            if (direct.empty()) break;

            /* Remove the direct dependencies from ‘builds’. This will
               cause them to be destroyed. */
            for (auto & b : direct) {
                auto builds_(builds.lock());
                b->finishedInDB = true;
                builds_->erase(b->id);
                buildIDs.push_back(b->id);
            }
        }

        /* Send notification about the builds that have this step as
           the top-level. */
        for (auto id : buildIDs) {
            {
                auto notificationSenderQueue_(notificationSenderQueue.lock());
                notificationSenderQueue_->push(NotificationItem(id, std::vector<BuildID>()));
            }
            notificationSenderWakeup.notify_one();
        }

        /* Wake up any dependent steps that have no other
           dependencies. */
        {
            auto step_(step->state.lock());
            for (auto & rdepWeak : step_->rdeps) {
                auto rdep = rdepWeak.lock();
                if (!rdep) continue;

                bool runnable = false;
                {
                    auto rdep_(rdep->state.lock());
                    rdep_->deps.erase(step);
                    /* Note: if the step has not finished
                       initialisation yet, it will be made runnable in
                       createStep(), if appropriate. */
                    if (rdep_->deps.empty() && rdep_->created) runnable = true;
                }

                if (runnable) makeRunnable(rdep);
            }
        }

    } else {

        /* Register failure in the database for all Build objects that
           directly or indirectly depend on this step. */

        std::vector<BuildID> dependentIDs;

        while (true) {

            /* Get the builds and steps that depend on this step. */
            std::set<Build::ptr> indirect;
            {
                auto steps_(steps.lock());
                std::set<Step::ptr> steps;
                getDependents(step, indirect, steps);

                /* If there are no builds left, delete all referring
                   steps from ‘steps’. As for the success case, we can
                   be certain no new referrers can be added. */
                if (indirect.empty()) {
                    for (auto & s : steps) {
                        printMsg(lvlDebug, format("finishing build step ‘%1%’") % s->drvPath);
                        steps_->erase(s->drvPath);
                    }
                    break;
                }
            }

            /* Update the database. */
            {
                pqxx::work txn(*conn);

                BuildStatus buildStatus =
                    result.status == RemoteResult::rrPermanentFailure ? bsFailed :
                    result.status == RemoteResult::rrTimedOut ? bsTimedOut :
                    bsAborted;
                BuildStepStatus buildStepStatus =
                    result.status == RemoteResult::rrPermanentFailure ? bssFailed :
                    result.status == RemoteResult::rrTimedOut ? bssTimedOut :
                    bssAborted;

                /* For regular failures, we don't care about the error
                   message. */
                if (buildStatus != bsAborted) result.errorMsg = "";

                /* Create failed build steps for every build that depends
                   on this. For cached failures, only create a step for
                   builds that don't have this step as top-level
                   (otherwise the user won't be able to see what caused
                   the build to fail). */
                for (auto & build2 : indirect) {
                    if ((cachedFailure && build2->drvPath == step->drvPath) ||
                        (!cachedFailure && build == build2) ||
                        build2->finishedInDB)
                        continue;
                    createBuildStep(txn, 0, build2, step, machine->sshName,
                        buildStepStatus, result.errorMsg, build == build2 ? 0 : build->id);
                }

                if (!cachedFailure)
                    finishBuildStep(txn, result.startTime, result.stopTime, build->id,
                        stepNr, machine->sshName, buildStepStatus, result.errorMsg);

                /* Mark all builds that depend on this derivation as failed. */
                for (auto & build2 : indirect) {
                    if (build2->finishedInDB) continue;
                    printMsg(lvlError, format("marking build %1% as failed") % build2->id);
                    txn.parameterized
                        ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $4, isCachedBuild = $5 where id = $1 and finished = 0")
                        (build2->id)
                        ((int) (build2->drvPath != step->drvPath && buildStatus == bsFailed ? bsDepFailed : buildStatus))
                        (result.startTime)
                        (result.stopTime)
                        (cachedFailure ? 1 : 0).exec();
                    nrBuildsDone++;
                }

                /* Remember failed paths in the database so that they
                   won't be built again. */
                if (!cachedFailure && result.status == RemoteResult::rrPermanentFailure)
                    for (auto & path : outputPaths(step->drv))
                        txn.parameterized("insert into FailedPaths values ($1)")(path).exec();

                txn.commit();
            }

            /* Remove the indirect dependencies from ‘builds’. This
               will cause them to be destroyed. */
            for (auto & b : indirect) {
                auto builds_(builds.lock());
                b->finishedInDB = true;
                builds_->erase(b->id);
                dependentIDs.push_back(b->id);
                if (buildOne == b->id) quit = true;
            }
        }

        /* Send notification about this build and its dependents. */
        {
            auto notificationSenderQueue_(notificationSenderQueue.lock());
            notificationSenderQueue_->push(NotificationItem(build->id, dependentIDs));
        }
        notificationSenderWakeup.notify_one();

    }

    // FIXME: keep stats about aborted steps?
    nrStepsDone++;
    totalStepTime += stepStopTime - stepStartTime;
    totalStepBuildTime += result.stopTime - result.startTime;
    machine->state->nrStepsDone++;
    machine->state->totalStepTime += stepStopTime - stepStartTime;
    machine->state->totalStepBuildTime += result.stopTime - result.startTime;

    if (quit) exit(0); // testing hack

    return false;
}


void State::markSucceededBuild(pqxx::work & txn, Build::ptr build,
    const BuildResult & res, bool isCachedBuild, time_t startTime, time_t stopTime)
{
    printMsg(lvlInfo, format("marking build %1% as succeeded") % build->id);

    if (build->finishedInDB) return;

    txn.parameterized
        ("update Builds set finished = 1, busy = 0, buildStatus = $2, startTime = $3, stopTime = $4, size = $5, closureSize = $6, releaseName = $7, isCachedBuild = $8 where id = $1 and finished = 0")
        (build->id)
        ((int) (res.failed ? bsFailedWithOutput : bsSuccess))
        (startTime)
        (stopTime)
        (res.size)
        (res.closureSize)
        (res.releaseName, res.releaseName != "")
        (isCachedBuild ? 1 : 0).exec();

    unsigned int productNr = 1;
    for (auto & product : res.products) {
        txn.parameterized
            ("insert into BuildProducts (build, productnr, type, subtype, fileSize, sha1hash, sha256hash, path, name, defaultPath) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)")
            (build->id)
            (productNr++)
            (product.type)
            (product.subtype)
            (product.fileSize, product.isRegular)
            (printHash(product.sha1hash), product.isRegular)
            (printHash(product.sha256hash), product.isRegular)
            (product.path)
            (product.name)
            (product.defaultPath).exec();
    }

    nrBuildsDone++;
}


bool State::checkCachedFailure(Step::ptr step, Connection & conn)
{
    pqxx::work txn(conn);
    for (auto & path : outputPaths(step->drv))
        if (!txn.parameterized("select 1 from FailedPaths where path = $1")(path).exec().empty())
            return true;
    return false;
}


void State::logCompressor()
{
    while (true) {
        try {

            Path logPath;
            {
                auto logCompressorQueue_(logCompressorQueue.lock());
                while (logCompressorQueue_->empty())
                    logCompressorQueue_.wait(logCompressorWakeup);
                logPath = logCompressorQueue_->front();
                logCompressorQueue_->pop();
            }

            if (!pathExists(logPath)) continue;

            printMsg(lvlChatty, format("compressing log file ‘%1%’") % logPath);

            Path tmpPath = logPath + ".bz2.tmp";

            AutoCloseFD fd = open(tmpPath.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0644);

            // FIXME: use libbz2

            Pid pid = startProcess([&]() {
                if (dup2(fd, STDOUT_FILENO) == -1)
                    throw SysError("cannot dup output pipe to stdout");
                execlp("bzip2", "bzip2", "-c", logPath.c_str(), nullptr);
                throw SysError("cannot start bzip2");
            });

            int res = pid.wait(true);

            if (res != 0)
                throw Error(format("bzip2 returned exit code %1% while compressing ‘%2%’")
                    % res % logPath);

            if (rename(tmpPath.c_str(), (logPath + ".bz2").c_str()) != 0)
                throw SysError(format("renaming ‘%1%’") % tmpPath);

            if (unlink(logPath.c_str()) != 0)
                throw SysError(format("unlinking ‘%1%’") % logPath);

        } catch (std::exception & e) {
            printMsg(lvlError, format("log compressor: %1%") % e.what());
            sleep(5);
        }
    }
}


void State::notificationSender()
{
    while (true) {
        try {

            NotificationItem item;
            {
                auto notificationSenderQueue_(notificationSenderQueue.lock());
                while (notificationSenderQueue_->empty())
                    notificationSenderQueue_.wait(notificationSenderWakeup);
                item = notificationSenderQueue_->front();
                notificationSenderQueue_->pop();
            }

            printMsg(lvlChatty, format("sending notification about build %1%") % item.first);

            Pid pid = startProcess([&]() {
                Strings argv({"hydra-notify", "build", int2String(item.first)});
                for (auto id : item.second)
                    argv.push_back(int2String(id));
                execvp("hydra-notify", (char * *) stringsToCharPtrs(argv).data()); // FIXME: remove cast
                throw SysError("cannot start hydra-notify");
            });

            int res = pid.wait(true);

            if (res != 0)
                throw Error(format("hydra-build returned exit code %1% notifying about build %2%")
                    % res % item.first);

        } catch (std::exception & e) {
            printMsg(lvlError, format("notification sender: %1%") % e.what());
            sleep(5);
        }
    }
}


std::shared_ptr<PathLocks> State::acquireGlobalLock()
{
    Path lockPath = hydraData + "/queue-runner";

    auto lock = std::make_shared<PathLocks>();
    if (!lock->lockPaths(PathSet({lockPath}), "", false)) return 0;

    return lock;
}


void State::dumpStatus(Connection & conn, bool log)
{
    std::ostringstream out;

    {
        JSONObject root(out);
        time_t now = time(0);
        root.attr("status", "up");
        root.attr("time", time(0));
        root.attr("uptime", now - startedAt);
        root.attr("pid", getpid());
        {
            auto builds_(builds.lock());
            root.attr("nrQueuedBuilds", builds_->size());
        }
        {
            auto steps_(steps.lock());
            for (auto i = steps_->begin(); i != steps_->end(); )
                if (i->second.lock()) ++i; else i = steps_->erase(i);
            root.attr("nrUnfinishedSteps", steps_->size());
        }
        {
            auto runnable_(runnable.lock());
            for (auto i = runnable_->begin(); i != runnable_->end(); )
                if (i->lock()) ++i; else i = runnable_->erase(i);
            root.attr("nrRunnableSteps", runnable_->size());
        }
        root.attr("nrActiveSteps", nrActiveSteps);
        root.attr("nrStepsBuilding", nrStepsBuilding);
        root.attr("nrStepsCopyingTo", nrStepsCopyingTo);
        root.attr("nrStepsCopyingFrom", nrStepsCopyingFrom);
        root.attr("bytesSent", bytesSent);
        root.attr("bytesReceived", bytesReceived);
        root.attr("nrBuildsRead", nrBuildsRead);
        root.attr("nrBuildsDone", nrBuildsDone);
        root.attr("nrStepsDone", nrStepsDone);
        root.attr("nrRetries", nrRetries);
        root.attr("maxNrRetries", maxNrRetries);
        if (nrStepsDone) {
            root.attr("totalStepTime", totalStepTime);
            root.attr("totalStepBuildTime", totalStepBuildTime);
            root.attr("avgStepTime"); out << (float) totalStepTime / nrStepsDone;
            root.attr("avgStepBuildTime"); out << (float) totalStepBuildTime / nrStepsDone;
        }
        root.attr("nrQueueWakeups", nrQueueWakeups);
        root.attr("nrDispatcherWakeups", nrDispatcherWakeups);
        root.attr("nrDbConnections", dbPool.count());
        {
            root.attr("machines");
            JSONObject nested(out);
            auto machines_(machines.lock());
            for (auto & i : *machines_) {
                auto & m(i.second);
                auto & s(m->state);
                nested.attr(m->sshName);
                JSONObject nested2(out);
                nested2.attr("currentJobs", s->currentJobs);
                nested2.attr("nrStepsDone", s->nrStepsDone);
                if (m->state->nrStepsDone) {
                    nested2.attr("totalStepTime", s->totalStepTime);
                    nested2.attr("totalStepBuildTime", s->totalStepBuildTime);
                    nested2.attr("avgStepTime"); out << (float) s->totalStepTime / s->nrStepsDone;
                    nested2.attr("avgStepBuildTime"); out << (float) s->totalStepBuildTime / s->nrStepsDone;
                }
            }
        }
    }

    if (log) printMsg(lvlInfo, format("status: %1%") % out.str());

    {
        pqxx::work txn(conn);
        // FIXME: use PostgreSQL 9.5 upsert.
        txn.exec("delete from SystemStatus where what = 'queue-runner'");
        txn.parameterized("insert into SystemStatus values ('queue-runner', $1)")(out.str()).exec();
        txn.exec("notify status_dumped");
        txn.commit();
    }
}


void State::showStatus()
{
    auto conn(dbPool.get());
    receiver statusDumped(*conn, "status_dumped");

    string status;
    bool barf = false;

    /* Get the last JSON status dump from the database. */
    {
        pqxx::work txn(*conn);
        auto res = txn.exec("select status from SystemStatus where what = 'queue-runner'");
        if (res.size()) status = res[0][0].as<string>();
    }

    if (status != "") {

        /* If the status is not empty, then the queue runner is
           running. Ask it to update the status dump. */
        {
            pqxx::work txn(*conn);
            txn.exec("notify dump_status");
            txn.commit();
        }

        /* Wait until it has done so. */
        barf = conn->await_notification(5, 0) == 0;

        /* Get the new status. */
        {
            pqxx::work txn(*conn);
            auto res = txn.exec("select status from SystemStatus where what = 'queue-runner'");
            if (res.size()) status = res[0][0].as<string>();
        }

    }

    if (status == "") status = R"({"status":"down"})";

    std::cout << status << "\n";

    if (barf)
        throw Error("queue runner did not respond; status information may be wrong");
}


void State::unlock()
{
    auto lock = acquireGlobalLock();
    if (!lock)
        throw Error("hydra-queue-runner is currently running");

    auto conn(dbPool.get());

    clearBusy(*conn, 0);

    {
        pqxx::work txn(*conn);
        txn.exec("delete from SystemStatus where what = 'queue-runner'");
        txn.commit();
    }
}


void State::run(BuildID buildOne)
{
    startedAt = time(0);
    this->buildOne = buildOne;

    auto lock = acquireGlobalLock();
    if (!lock)
        throw Error("hydra-queue-runner is already running");

    {
        auto conn(dbPool.get());
        clearBusy(*conn, 0);
        dumpStatus(*conn, false);
    }

    loadMachinesFile();

    std::thread(&State::monitorMachinesFile, this).detach();

    std::thread(&State::queueMonitor, this).detach();

    std::thread(&State::dispatcher, this).detach();

    /* Run a log compressor thread. If needed, we could start more
       than one. */
    std::thread(&State::logCompressor, this).detach();

    /* Idem for notification sending. */
    std::thread(&State::notificationSender, this).detach();

    /* Monitor the database for status dump requests (e.g. from
       ‘hydra-queue-runner --status’). */
    while (true) {
        try {
            auto conn(dbPool.get());
            receiver dumpStatus(*conn, "dump_status");
            while (true) {
                bool timeout = conn->await_notification(300, 0) == 0;
                State::dumpStatus(*conn, timeout);
            }
        } catch (std::exception & e) {
            printMsg(lvlError, format("main thread: %1%") % e.what());
            sleep(10); // probably a DB problem, so don't retry right away
        }
    }
}


int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();

        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);

        bool unlock = false;
        bool status = false;
        BuildID buildOne = 0;

        parseCmdLine(argc, argv, [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--unlock")
                unlock = true;
            else if (*arg == "--status")
                status = true;
            else if (*arg == "--build-one") {
                if (!string2Int<BuildID>(getArg(*arg, arg, end), buildOne))
                    throw Error("‘--build-one’ requires a build ID");
            } else
                return false;
            return true;
        });

        settings.buildVerbosity = lvlVomit;
        settings.useSubstitutes = false;
        settings.lockCPU = false;

        State state;
        if (status)
            state.showStatus();
        else if (unlock)
            state.unlock();
        else
            state.run(buildOne);
    });
}

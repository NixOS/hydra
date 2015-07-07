#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <map>
#include <memory>
#include <queue>

#include "db.hh"
#include "counter.hh"
#include "pathlocks.hh"
#include "pool.hh"
#include "sync.hh"

#include "store-api.hh"
#include "derivations.hh"


typedef unsigned int BuildID;

typedef std::chrono::time_point<std::chrono::system_clock> system_time;


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


struct RemoteResult
{
    enum {
        rrSuccess = 0,
        rrPermanentFailure = 1,
        rrTimedOut = 2,
        rrMiscFailure = 3
    } status = rrMiscFailure;
    std::string errorMsg;
    time_t startTime = 0, stopTime = 0;
    nix::Path logFile;
};


struct Step;
struct BuildResult;


struct Build
{
    typedef std::shared_ptr<Build> ptr;
    typedef std::weak_ptr<Build> wptr;

    BuildID id;
    nix::Path drvPath;
    std::map<std::string, nix::Path> outputs;
    std::string fullJobName;
    unsigned int maxSilentTime, buildTimeout;

    std::shared_ptr<Step> toplevel;

    std::atomic_bool finishedInDB{false};
};


struct Step
{
    typedef std::shared_ptr<Step> ptr;
    typedef std::weak_ptr<Step> wptr;

    nix::Path drvPath;
    nix::Derivation drv;
    std::set<std::string> requiredSystemFeatures;
    bool preferLocalBuild;

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

        /* Mutex to prevent multiple threads from sending data to the
           same machine (which would be inefficient). */
        std::mutex sendLock;
    };

    State::ptr state;

    bool supportsStep(Step::ptr step)
    {
        if (systemTypes.find(step->drv.platform) == systemTypes.end()) return false;
        for (auto & f : mandatoryFeatures)
            if (step->requiredSystemFeatures.find(f) == step->requiredSystemFeatures.end()
                && !(step->preferLocalBuild && f == "local"))
                return false;
        for (auto & f : step->requiredSystemFeatures)
            if (supportedFeatures.find(f) == supportedFeatures.end()) return false;
        return true;
    }
};


class State
{
private:

    nix::Path hydraData, logDir;

    nix::StringSet localPlatforms;

    /* The queued builds. */
    typedef std::map<BuildID, Build::ptr> Builds;
    Sync<Builds> builds;

    /* All active or pending build steps (i.e. dependencies of the
       queued builds). Note that these are weak pointers. Steps are
       kept alive by being reachable from Builds or by being in
       progress. */
    typedef std::map<nix::Path, Step::wptr> Steps;
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
    typedef std::map<std::string, Machine::ptr> Machines;
    Sync<Machines> machines; // FIXME: use atomic_shared_ptr

    nix::Path machinesFile;
    struct stat machinesFileStat;

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
    Sync<std::queue<nix::Path>> logCompressorQueue;
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
        const std::string & machine, BuildStepStatus status, const std::string & errorMsg = "",
        BuildID propagatedFrom = 0);

    void updateBuild(pqxx::work & txn, Build::ptr build, BuildStatus status);

    void queueMonitor();

    void queueMonitorLoop();

    void getQueuedBuilds(Connection & conn, std::shared_ptr<nix::StoreAPI> store, unsigned int & lastBuildId);

    void removeCancelledBuilds(Connection & conn);

    Step::ptr createStep(std::shared_ptr<nix::StoreAPI> store, const nix::Path & drvPath,
        Build::ptr referringBuild, Step::ptr referringStep, std::set<nix::Path> & finishedDrvs,
        std::set<Step::ptr> & newSteps, std::set<Step::ptr> & newRunnable);

    void makeRunnable(Step::ptr step);

    /* The thread that selects and starts runnable builds. */
    void dispatcher();

    void wakeDispatcher();

    void builder(Step::ptr step, Machine::ptr machine, std::shared_ptr<MaintainCount> reservation);

    /* Perform the given build step. Return true if the step is to be
       retried. */
    bool doBuildStep(std::shared_ptr<nix::StoreAPI> store, Step::ptr step,
        Machine::ptr machine);

    void buildRemote(std::shared_ptr<nix::StoreAPI> store,
        Machine::ptr machine, Step::ptr step,
        unsigned int maxSilentTime, unsigned int buildTimeout,
        RemoteResult & result);

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
    std::shared_ptr<nix::PathLocks> acquireGlobalLock();

    void dumpStatus(Connection & conn, bool log);

public:

    void showStatus();

    void unlock();

    void run(BuildID buildOne = 0);
};

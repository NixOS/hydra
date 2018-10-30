#pragma once

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <map>
#include <memory>
#include <queue>

#include "db.hh"
#include "token-server.hh"

#include "parsed-derivations.hh"
#include "pathlocks.hh"
#include "pool.hh"
#include "store-api.hh"
#include "sync.hh"


typedef unsigned int BuildID;

typedef std::chrono::time_point<std::chrono::system_clock> system_time;

typedef std::atomic<unsigned long> counter;


typedef enum {
    bsSuccess = 0,
    bsFailed = 1,
    bsDepFailed = 2, // builds only
    bsAborted = 3,
    bsCancelled = 4,
    bsFailedWithOutput = 6, // builds only
    bsTimedOut = 7,
    bsCachedFailure = 8, // steps only
    bsUnsupported = 9,
    bsLogLimitExceeded = 10,
    bsNarSizeLimitExceeded = 11,
    bsNotDeterministic = 12,
    bsBusy = 100, // not stored
} BuildStatus;


typedef enum {
    ssPreparing = 1,
    ssConnecting = 10,
    ssSendingInputs = 20,
    ssBuilding = 30,
    ssReceivingOutputs = 40,
    ssPostProcessing = 50,
} StepState;


struct RemoteResult
{
    BuildStatus stepStatus = bsAborted;
    bool canRetry = false; // for bsAborted
    bool isCached = false; // for bsSucceed
    bool canCache = false; // for bsFailed
    std::string errorMsg; // for bsAborted

    unsigned int timesBuilt = 0;
    bool isNonDeterministic = false;

    time_t startTime = 0, stopTime = 0;
    unsigned int overhead = 0;
    nix::Path logFile;
    std::unique_ptr<nix::TokenServer::Token> tokens;
    std::shared_ptr<nix::FSAccessor> accessor;

    BuildStatus buildStatus()
    {
        return stepStatus == bsCachedFailure ? bsFailed : stepStatus;
    }
};


struct Step;
struct BuildOutput;


class Jobset
{
public:

    typedef std::shared_ptr<Jobset> ptr;
    typedef std::weak_ptr<Jobset> wptr;

    static const time_t schedulingWindow = 24 * 60 * 60;

private:

    std::atomic<time_t> seconds{0};
    std::atomic<unsigned int> shares{1};

    /* The start time and duration of the most recent build steps. */
    nix::Sync<std::map<time_t, time_t>> steps;

public:

    double shareUsed()
    {
        return (double) seconds / shares;
    }

    void setShares(int shares_)
    {
        assert(shares_ > 0);
        shares = shares_;
    }

    time_t getSeconds() { return seconds; }

    void addStep(time_t startTime, time_t duration);

    void pruneSteps();
};


struct Build
{
    typedef std::shared_ptr<Build> ptr;
    typedef std::weak_ptr<Build> wptr;

    BuildID id;
    nix::Path drvPath;
    std::map<std::string, nix::Path> outputs;
    std::string projectName, jobsetName, jobName;
    time_t timestamp;
    unsigned int maxSilentTime, buildTimeout;
    int localPriority, globalPriority;

    std::shared_ptr<Step> toplevel;

    Jobset::ptr jobset;

    std::atomic_bool finishedInDB{false};

    std::string fullJobName()
    {
        return projectName + ":" + jobsetName + ":" + jobName;
    }

    void propagatePriorities();
};


struct Step
{
    typedef std::shared_ptr<Step> ptr;
    typedef std::weak_ptr<Step> wptr;

    nix::Path drvPath;
    nix::Derivation drv;
    std::unique_ptr<nix::ParsedDerivation> parsedDrv;
    std::set<std::string> requiredSystemFeatures;
    bool preferLocalBuild;
    bool isDeterministic;
    std::string systemType; // concatenation of drv.platform and requiredSystemFeatures

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

        /* Jobsets to which this step belongs. Used for determining
           scheduling priority. */
        std::set<Jobset::ptr> jobsets;

        /* Number of times we've tried this step. */
        unsigned int tries = 0;

        /* Point in time after which the step can be retried. */
        system_time after;

        /* The highest global priority of any build depending on this
           step. */
        int highestGlobalPriority{0};

        /* The highest local priority of any build depending on this
           step. */
        int highestLocalPriority{0};

        /* The lowest ID of any build depending on this step. */
        BuildID lowestBuildID{std::numeric_limits<BuildID>::max()};

        /* The time at which this step became runnable. */
        system_time runnableSince;
    };

    std::atomic_bool finished{false}; // debugging

    nix::Sync<State> state;

    ~Step()
    {
        //printMsg(lvlError, format("destroying step %1%") % drvPath);
    }
};


void getDependents(Step::ptr step, std::set<Build::ptr> & builds, std::set<Step::ptr> & steps);

/* Call ‘visitor’ for a step and all its dependencies. */
void visitDependencies(std::function<void(Step::ptr)> visitor, Step::ptr step);


struct Machine
{
    typedef std::shared_ptr<Machine> ptr;

    bool enabled{true};

    std::string sshName, sshKey;
    std::set<std::string> systemTypes, supportedFeatures, mandatoryFeatures;
    unsigned int maxJobs = 1;
    float speedFactor = 1.0;
    std::string sshPublicHostKey;

    struct State {
        typedef std::shared_ptr<State> ptr;
        counter currentJobs{0};
        counter nrStepsDone{0};
        counter totalStepTime{0}; // total time for steps, including closure copying
        counter totalStepBuildTime{0}; // total build time for steps
        std::atomic<time_t> idleSince{0};

        struct ConnectInfo
        {
            system_time lastFailure, disabledUntil;
            unsigned int consecutiveFailures;
        };
        nix::Sync<ConnectInfo> connectInfo;

        /* Mutex to prevent multiple threads from sending data to the
           same machine (which would be inefficient). */
        std::timed_mutex sendLock;
    };

    State::ptr state;

    bool supportsStep(Step::ptr step)
    {
        /* Check that this machine is of the type required by the
           step. */
        if (!systemTypes.count(step->drv.platform == "builtin" ? nix::settings.thisSystem : step->drv.platform))
            return false;

        /* Check that the step requires all mandatory features of this
           machine. (Thus, a machine with the mandatory "benchmark"
           feature will *only* execute steps that require
           "benchmark".) The "preferLocalBuild" bit of a step is
           mapped to the "local" feature; thus machines that have
           "local" as a mandatory feature will only do
           preferLocalBuild steps. */
        for (auto & f : mandatoryFeatures)
            if (!step->requiredSystemFeatures.count(f)
                && !(f == "local" && step->preferLocalBuild))
                return false;

        /* Check that the machine supports all features required by
           the step. */
        for (auto & f : step->requiredSystemFeatures)
            if (!supportedFeatures.count(f)) return false;

        return true;
    }
};


class Config;


class State
{
private:

    std::unique_ptr<Config> config;

    // FIXME: Make configurable.
    const unsigned int maxTries = 5;
    const unsigned int retryInterval = 60; // seconds
    const float retryBackoff = 3.0;
    const unsigned int maxParallelCopyClosure = 4;

    nix::Path hydraData, logDir;

    bool useSubstitutes = false;

    /* The queued builds. */
    typedef std::map<BuildID, Build::ptr> Builds;
    nix::Sync<Builds> builds;

    /* The jobsets. */
    typedef std::map<std::pair<std::string, std::string>, Jobset::ptr> Jobsets;
    nix::Sync<Jobsets> jobsets;

    /* All active or pending build steps (i.e. dependencies of the
       queued builds). Note that these are weak pointers. Steps are
       kept alive by being reachable from Builds or by being in
       progress. */
    typedef std::map<nix::Path, Step::wptr> Steps;
    nix::Sync<Steps> steps;

    /* Build steps that have no unbuilt dependencies. */
    typedef std::list<Step::wptr> Runnable;
    nix::Sync<Runnable> runnable;

    /* CV for waking up the dispatcher. */
    nix::Sync<bool> dispatcherWakeup;
    std::condition_variable dispatcherWakeupCV;

    /* PostgreSQL connection pool. */
    nix::Pool<Connection> dbPool;

    /* The build machines. */
    typedef std::map<std::string, Machine::ptr> Machines;
    nix::Sync<Machines> machines; // FIXME: use atomic_shared_ptr

    /* Various stats. */
    time_t startedAt;
    counter nrBuildsRead{0};
    counter buildReadTimeMs{0};
    counter nrBuildsDone{0};
    counter nrStepsStarted{0};
    counter nrStepsDone{0};
    counter nrStepsBuilding{0};
    counter nrStepsCopyingTo{0};
    counter nrStepsCopyingFrom{0};
    counter nrStepsWaiting{0};
    counter nrRetries{0};
    counter maxNrRetries{0};
    counter totalStepTime{0}; // total time for steps, including closure copying
    counter totalStepBuildTime{0}; // total build time for steps
    counter nrQueueWakeups{0};
    counter nrDispatcherWakeups{0};
    counter dispatchTimeMs{0};
    counter bytesSent{0};
    counter bytesReceived{0};
    counter nrActiveDbUpdates{0};
    counter nrNotificationsDone{0};
    counter nrNotificationsFailed{0};
    counter nrNotificationsInProgress{0};
    counter nrNotificationTimeMs{0};

    /* Notification sender work queue. FIXME: if hydra-queue-runner is
       killed before it has finished sending notifications about a
       build, then the notifications may be lost. It would be better
       to mark builds with pending notification in the database. */
    struct NotificationItem
    {
        enum class Type : char {
           BuildStarted,
           BuildFinished,
           StepFinished,
        };
        Type type;
        BuildID id;
        std::vector<BuildID> dependentIds;
        unsigned int stepNr;
        nix::Path logPath;
    };
    nix::Sync<std::queue<NotificationItem>> notificationSenderQueue;
    std::condition_variable notificationSenderWakeup;

    void enqueueNotificationItem(const NotificationItem && item)
    {
        {
            auto notificationSenderQueue_(notificationSenderQueue.lock());
            notificationSenderQueue_->emplace(item);
        }
        notificationSenderWakeup.notify_one();
    }

    /* Specific build to do for --build-one (testing only). */
    BuildID buildOne;

    /* Statistics per machine type for the Hydra auto-scaler. */
    struct MachineType
    {
        unsigned int runnable{0}, running{0};
        system_time lastActive;
        std::chrono::seconds waitTime; // time runnable steps have been waiting
    };

    nix::Sync<std::map<std::string, MachineType>> machineTypes;

    struct MachineReservation
    {
        typedef std::shared_ptr<MachineReservation> ptr;
        State & state;
        Step::ptr step;
        Machine::ptr machine;
        MachineReservation(State & state, Step::ptr step, Machine::ptr machine);
        ~MachineReservation();
    };

    struct ActiveStep
    {
        Step::ptr step;

        struct State
        {
            pid_t pid = -1;
            bool cancelled = false;
        };

        nix::Sync<State> state_;
    };

    nix::Sync<std::set<std::shared_ptr<ActiveStep>>> activeSteps_;

    std::atomic<time_t> lastDispatcherCheck{0};

    std::shared_ptr<nix::Store> localStore;
    std::shared_ptr<nix::Store> _destStore;

    /* Token server to prevent threads from allocating too many big
       strings concurrently while importing NARs from the build
       machines. When a thread imports a NAR of size N, it will first
       acquire N memory tokens, causing it to block until that many
       tokens are available. */
    nix::TokenServer memoryTokens;

    size_t maxOutputSize;
    size_t maxLogSize;

    time_t lastStatusLogged = 0;
    const int statusLogInterval = 300;

    /* Steps that were busy while we encounted a PostgreSQL
       error. These need to be cleared at a later time to prevent them
       from showing up as busy until the queue runner is restarted. */
    nix::Sync<std::set<std::pair<BuildID, int>>> orphanedSteps;

    /* How often the build steps of a jobset should be repeated in
       order to detect non-determinism. */
    std::map<std::pair<std::string, std::string>, unsigned int> jobsetRepeats;

    bool uploadLogsToBinaryCache;

    /* Where to store GC roots. Defaults to
       /nix/var/nix/gcroots/per-user/$USER/hydra-roots, overridable
       via gc_roots_dir. */
    nix::Path rootsDir;

public:
    State();

private:

    nix::MaintainCount<counter> startDbUpdate();

    /* Return a store object to store build results. */
    nix::ref<nix::Store> getDestStore();

    void clearBusy(Connection & conn, time_t stopTime);

    void parseMachines(const std::string & contents);

    /* Thread to reload /etc/nix/machines periodically. */
    void monitorMachinesFile();

    unsigned int allocBuildStep(pqxx::work & txn, BuildID buildId);

    unsigned int createBuildStep(pqxx::work & txn, time_t startTime, BuildID buildId, Step::ptr step,
        const std::string & machine, BuildStatus status, const std::string & errorMsg = "",
        BuildID propagatedFrom = 0);

    void updateBuildStep(pqxx::work & txn, BuildID buildId, unsigned int stepNr, StepState stepState);

    void finishBuildStep(pqxx::work & txn, const RemoteResult & result, BuildID buildId, unsigned int stepNr,
        const std::string & machine);

    int createSubstitutionStep(pqxx::work & txn, time_t startTime, time_t stopTime,
        Build::ptr build, const nix::Path & drvPath, const std::string & outputName, const nix::Path & storePath);

    void updateBuild(pqxx::work & txn, Build::ptr build, BuildStatus status);

    void queueMonitor();

    void queueMonitorLoop();

    /* Check the queue for new builds. */
    bool getQueuedBuilds(Connection & conn,
        nix::ref<nix::Store> destStore, unsigned int & lastBuildId);

    /* Handle cancellation, deletion and priority bumps. */
    void processQueueChange(Connection & conn);

    BuildOutput getBuildOutputCached(Connection & conn, nix::ref<nix::Store> destStore,
        const nix::Derivation & drv);

    Step::ptr createStep(nix::ref<nix::Store> store,
        Connection & conn, Build::ptr build, const nix::Path & drvPath,
        Build::ptr referringBuild, Step::ptr referringStep, std::set<nix::Path> & finishedDrvs,
        std::set<Step::ptr> & newSteps, std::set<Step::ptr> & newRunnable);

    Jobset::ptr createJobset(pqxx::work & txn,
        const std::string & projectName, const std::string & jobsetName);

    void processJobsetSharesChange(Connection & conn);

    void makeRunnable(Step::ptr step);

    /* The thread that selects and starts runnable builds. */
    void dispatcher();

    system_time doDispatch();

    void wakeDispatcher();

    void builder(MachineReservation::ptr reservation);

    /* Perform the given build step. Return true if the step is to be
       retried. */
    enum StepResult { sDone, sRetry, sMaybeCancelled };
    StepResult doBuildStep(nix::ref<nix::Store> destStore,
        MachineReservation::ptr reservation,
        std::shared_ptr<ActiveStep> activeStep);

    void buildRemote(nix::ref<nix::Store> destStore,
        Machine::ptr machine, Step::ptr step,
        unsigned int maxSilentTime, unsigned int buildTimeout,
        unsigned int repeats,
        RemoteResult & result, std::shared_ptr<ActiveStep> activeStep,
        std::function<void(StepState)> updateStep);

    void markSucceededBuild(pqxx::work & txn, Build::ptr build,
        const BuildOutput & res, bool isCachedBuild, time_t startTime, time_t stopTime);

    bool checkCachedFailure(Step::ptr step, Connection & conn);

    /* Thread that asynchronously invokes hydra-notify to send build
       notifications. */
    void notificationSender();

    /* Acquire the global queue runner lock, or null if somebody else
       has it. */
    std::shared_ptr<nix::PathLocks> acquireGlobalLock();

    void dumpStatus(Connection & conn, bool log);

    void addRoot(const nix::Path & storePath);

public:

    void showStatus();

    void unlock();

    void run(BuildID buildOne = 0);
};

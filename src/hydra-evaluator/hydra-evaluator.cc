#include "db.hh"
#include "hydra-config.hh"
#include "pool.hh"
#include "shared.hh"
#include "signals.hh"

#include <algorithm>
#include <thread>
#include <cstring>
#include <optional>

#include <sys/types.h>
#include <sys/wait.h>

using namespace nix;

typedef std::pair<std::string, std::string> JobsetName;

class JobsetId {
    public:

    std::string project;
    std::string jobset;
    int id;


    JobsetId(const std::string & project, const std::string & jobset, int id)
        : project{ project }, jobset{ jobset }, id{ id }
    {
    }

    friend bool operator== (const JobsetId & lhs, const JobsetId & rhs);
    friend bool operator!= (const JobsetId & lhs, const JobsetId & rhs);
    friend bool operator< (const JobsetId & lhs, const JobsetId & rhs);


    friend bool operator== (const JobsetId & lhs, const JobsetName & rhs);
    friend bool operator!= (const JobsetId & lhs, const JobsetName & rhs);

    std::string display() const {
        return str(format("%1%:%2% (jobset#%3%)") % project % jobset % id);
    }
};
bool operator==(const JobsetId & lhs, const JobsetId & rhs)
{
    return lhs.id == rhs.id;
}

bool operator!=(const JobsetId & lhs, const JobsetId & rhs)
{
    return lhs.id != rhs.id;
}

bool operator<(const JobsetId & lhs, const JobsetId & rhs)
{
    return lhs.id < rhs.id;
}

bool operator==(const JobsetId & lhs, const JobsetName & rhs)
{
    return lhs.project == rhs.first && lhs.jobset == rhs.second;
}

bool operator!=(const JobsetId & lhs, const JobsetName & rhs)
{
    return ! (lhs == rhs);
}

enum class EvaluationStyle
{
    SCHEDULE = 1,
    ONESHOT = 2,
    ONE_AT_A_TIME = 3,
};

struct Evaluator
{
    std::unique_ptr<HydraConfig> config;

    nix::Pool<Connection> dbPool;

    struct Jobset
    {
        JobsetId name;
        std::optional<EvaluationStyle> evaluation_style;
        time_t lastCheckedTime, triggerTime;
        int checkInterval;
        Pid pid;
    };

    typedef std::map<JobsetId, Jobset> Jobsets;

    std::optional<JobsetName> evalOne;

    const size_t maxEvals;

    struct State
    {
        size_t runningEvals = 0;
        Jobsets jobsets;
    };

    Sync<State> state_;

    std::condition_variable childStarted;
    std::condition_variable maybeDoWork;

    const time_t notTriggered = std::numeric_limits<time_t>::max();

    Evaluator()
        : config(std::make_unique<HydraConfig>())
        , maxEvals(std::max((size_t) 1, (size_t) config->getIntOption("max_concurrent_evals", 4)))
    { }

    void readJobsets()
    {
        auto conn(dbPool.get());

        pqxx::work txn(*conn);

        auto res = txn.exec
            ("select j.id as id, project, j.name, lastCheckedTime, triggerTime, checkInterval, j.enabled as jobset_enabled "
             "from Jobsets j "
             "join Projects p on j.project = p.name "
             "where j.enabled != 0 and p.enabled != 0");


        auto state(state_.lock());

        std::set<JobsetId> seen;

        for (auto const & row : res) {
            auto name = JobsetId{row["project"].as<std::string>(), row["name"].as<std::string>(), row["id"].as<int>()};

            if (evalOne && name != *evalOne) continue;

            auto res = state->jobsets.try_emplace(name, Jobset{name});

            auto & jobset = res.first->second;
            jobset.lastCheckedTime = row["lastCheckedTime"].as<time_t>(0);
            jobset.triggerTime = row["triggerTime"].as<time_t>(notTriggered);
            jobset.checkInterval = row["checkInterval"].as<time_t>();
            switch (row["jobset_enabled"].as<int>(0)) {
                case 1:
                    jobset.evaluation_style = EvaluationStyle::SCHEDULE;
                    break;
                case 2:
                    jobset.evaluation_style = EvaluationStyle::ONESHOT;
                    break;
                case 3:
                    jobset.evaluation_style = EvaluationStyle::ONE_AT_A_TIME;
                    break;
            }

            seen.insert(name);
        }

        if (evalOne && seen.empty()) {
            printError("the specified jobset does not exist or is disabled");
            std::_Exit(1);
        }

        for (auto i = state->jobsets.begin(); i != state->jobsets.end(); )
            if (seen.count(i->first))
                ++i;
            else {
                printInfo("forgetting jobset ‘%s’", i->first.display());
                i = state->jobsets.erase(i);
            }
    }

    void startEval(State & state, Jobset & jobset)
    {
        time_t now = time(0);

        printInfo("starting evaluation of jobset ‘%s’ (last checked %d s ago)",
            jobset.name.display(),
            now - jobset.lastCheckedTime);

        {
            auto conn(dbPool.get());
            pqxx::work txn(*conn);
            txn.exec_params0
                ("update Jobsets set startTime = $1 where id = $2",
                 now,
                 jobset.name.id);
            txn.commit();
        }

        assert(jobset.pid == -1);

        jobset.pid = startProcess([&]() {
            Strings args = { "hydra-eval-jobset", jobset.name.project, jobset.name.jobset };
            execvp(args.front().c_str(), stringsToCharPtrs(args).data());
            throw SysError("executing ‘%1%’", args.front());
        });

        state.runningEvals++;

        childStarted.notify_one();
    }

    bool shouldEvaluate(Jobset & jobset)
    {
        if (jobset.pid != -1) {
            // Already running.
            debug("shouldEvaluate %s? no: already running",
                  jobset.name.display());
            return false;
        }

        if (jobset.triggerTime != std::numeric_limits<time_t>::max()) {
            // An evaluation of this Jobset is requested
            debug("shouldEvaluate %s? yes: requested",
                  jobset.name.display());
            return true;
        }

        if (jobset.checkInterval <= 0) {
            // Automatic scheduling is disabled. We allow requested
            // evaluations, but never schedule start one.
            debug("shouldEvaluate %s? no: checkInterval <= 0",
                  jobset.name.display());
            return false;
        }

        if (jobset.lastCheckedTime + jobset.checkInterval <= time(0)) {
            // Time to schedule a fresh evaluation. If the jobset
            // is a ONE_AT_A_TIME jobset, ensure the previous jobset
            // has no remaining, unfinished work.

            auto conn(dbPool.get());

            pqxx::work txn(*conn);

            if (jobset.evaluation_style == EvaluationStyle::ONE_AT_A_TIME) {
                auto evaluation_res = txn.exec_params
                    ("select id from JobsetEvals "
                     "where jobset_id = $1 "
                     "order by id desc limit 1"
                    ,jobset.name.id
                    );

                if (evaluation_res.empty()) {
                    // First evaluation, so allow scheduling.
                    debug("shouldEvaluate(one-at-a-time) %s? yes: no prior eval",
                          jobset.name.display());
                    return true;
                }

                auto evaluation_id = evaluation_res[0][0].as<int>();

                auto unfinished_build_res = txn.exec_params
                    ("select id from Builds "
                     "join JobsetEvalMembers "
                     "    on (JobsetEvalMembers.build = Builds.id) "
                     "where JobsetEvalMembers.eval = $1 "
                     "  and builds.finished = 0 "
                     " limit 1"
                    ,evaluation_id
                    );

                // If the previous evaluation has no unfinished builds
                // schedule!
                if (unfinished_build_res.empty()) {
                    debug("shouldEvaluate(one-at-a-time) %s? yes: no unfinished builds",
                          jobset.name.display());
                    return true;
                } else {
                    debug("shouldEvaluate(one-at-a-time) %s:%s? no: at least one unfinished build",
                           jobset.name.display());
                    return false;
                }


            } else {
                // EvaluationStyle::ONESHOT, EvaluationStyle::SCHEDULED
                debug("shouldEvaluate(oneshot/scheduled) %s? yes: checkInterval elapsed",
                      jobset.name.display());
                return true;
            }
        }

        return false;
    }

    void startEvals(State & state)
    {
        std::vector<Jobsets::iterator> sorted;

        /* Filter out jobsets that have been evaluated recently and have
           not been triggered. */
        for (auto i = state.jobsets.begin(); i != state.jobsets.end(); ++i)
            if (evalOne ||
                (i->second.evaluation_style && shouldEvaluate(i->second)))
                sorted.push_back(i);

        /* Put jobsets in order of ascending trigger time, last checked
           time, and name. */
        std::sort(sorted.begin(), sorted.end(),
            [](const Jobsets::iterator & a, const Jobsets::iterator & b) {
                return
                    a->second.triggerTime != b->second.triggerTime
                    ? a->second.triggerTime < b->second.triggerTime
                    : a->second.lastCheckedTime != b->second.lastCheckedTime
                      ? a->second.lastCheckedTime < b->second.lastCheckedTime
                      : a->first < b->first;
            });

        /* Start jobset evaluations up to the concurrency limit.*/
        for (auto & i : sorted) {
            if (state.runningEvals >= maxEvals) break;
            startEval(state, i->second);
        }
    }

    void loop()
    {
        auto state(state_.lock());

        while (true) {

            time_t now = time(0);

            std::chrono::seconds sleepTime = std::chrono::seconds::max();

            if (state->runningEvals < maxEvals) {
                for (auto & i : state->jobsets)
                    if (i.second.pid == -1 &&
                        i.second.checkInterval > 0)
                        sleepTime = std::min(sleepTime, std::chrono::seconds(
                                std::max((time_t) 1, i.second.lastCheckedTime - now + i.second.checkInterval)));
            }

            debug("waiting for %d s", sleepTime.count());
            if (sleepTime == std::chrono::seconds::max())
                state.wait(maybeDoWork);
            else
                state.wait_for(maybeDoWork, sleepTime);

            startEvals(*state);
        }
    }

    /* A thread that listens to PostgreSQL notifications about jobset
       changes, updates the jobsets map, and signals the main thread
       to start evaluations. */
    void databaseMonitor()
    {
        while (true) {

            try {

                auto conn(dbPool.get());

                receiver jobsetsAdded(*conn, "jobsets_added");
                receiver jobsetsDeleted(*conn, "jobsets_deleted");
                receiver jobsetsChanged(*conn, "jobset_scheduling_changed");

                while (true) {
                    /* Note: we read/notify before
                       await_notification() to ensure we don't miss a
                       state change. */
                    readJobsets();
                    maybeDoWork.notify_one();
                    conn->await_notification();
                    printInfo("received jobset event");
                }

            } catch (pqxx::broken_connection & e) {
                printError("Database connection broken: %s", e.what());
                std::_Exit(1);
            } catch (std::exception & e) {
                printError("exception in database monitor thread: %s", e.what());
                sleep(30);
            }
        }
    }

    /* A thread that reaps child processes.*/
    void reaper()
    {
        while (true) {
            {
                auto state(state_.lock());
                while (!state->runningEvals)
                    state.wait(childStarted);
            }

            int status;
            pid_t pid = waitpid(-1, &status, 0);
            if (pid == -1) {
                if (errno == EINTR) continue;
                throw SysError("waiting for children");
            }

            {
                auto state(state_.lock());
                assert(state->runningEvals);
                state->runningEvals--;

                // FIXME: should use a map.
                for (auto & i : state->jobsets) {
                    auto & jobset(i.second);

                    if (jobset.pid == pid) {
                        printInfo("evaluation of jobset ‘%s’ %s",
                            jobset.name.display(), statusToString(status));

                        auto now = time(0);

                        jobset.triggerTime = notTriggered;
                        jobset.lastCheckedTime = now;

                        try {

                            auto conn(dbPool.get());
                            pqxx::work txn(*conn);

                            /* Clear the trigger time to prevent this
                               jobset from getting stuck in an endless
                               failing eval loop. */
                            txn.exec_params0
                                ("update Jobsets set triggerTime = null where id = $1 and startTime is not null and triggerTime <= startTime",
                                 jobset.name.id);

                            /* Clear the start time. */
                            txn.exec_params0
                                ("update Jobsets set startTime = null where id = $1",
                                 jobset.name.id);

                            if (!WIFEXITED(status) || WEXITSTATUS(status) > 1) {
                                txn.exec_params0
                                    ("update Jobsets set errorMsg = $1, lastCheckedTime = $2, errorTime = $2, fetchErrorMsg = null where id = $3",
                                     fmt("evaluation %s", statusToString(status)),
                                     now,
                                     jobset.name.id);
                            }

                            txn.commit();

                        } catch (std::exception & e) {
                            printError("exception setting jobset error: %s", e.what());
                        }

                        jobset.pid.release();
                        maybeDoWork.notify_one();

                        if (evalOne) std::_Exit(0);

                        break;
                    }
                }
            }
        }
    }

    void unlock()
    {
        auto conn(dbPool.get());
        pqxx::work txn(*conn);
        txn.exec("update Jobsets set startTime = null");
        txn.commit();
    }

    void run()
    {
        unlock();

        /* Can't be bothered to shut down cleanly. Goodbye! */
        auto callback = createInterruptCallback([&]() { std::_Exit(1); });

        std::thread reaperThread([&]() { reaper(); });

        std::thread monitorThread([&]() { databaseMonitor(); });

        while (true) {
            try {
                loop();
            } catch (pqxx::broken_connection & e) {
                printError("Database connection broken: %s", e.what());
                std::_Exit(1);
            } catch (std::exception & e) {
                printError("exception in main loop: %s", e.what());
                sleep(30);
            }
        }
    }
};

int main(int argc, char * * argv)
{
    return handleExceptions(argv[0], [&]() {
        initNix();

        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGHUP, SIG_DFL);

        bool unlock = false;

        Evaluator evaluator;

        std::vector<std::string> args;

        parseCmdLine(argc, argv, [&](Strings::iterator & arg, const Strings::iterator & end) {
            if (*arg == "--unlock")
                unlock = true;
            else if (hasPrefix(*arg, "-"))
                return false;
            args.push_back(*arg);
            return true;
        });


        if (unlock)
            evaluator.unlock();
        else {
            if (!args.empty()) {
                if (args.size() != 2) throw UsageError("Syntax: hydra-evaluator [<project> <jobset>]");
                evaluator.evalOne = JobsetName(args[0], args[1]);
            }
            evaluator.run();
        }
    });
}

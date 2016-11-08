#include "shared.hh"
#include "db.hh"
#include "pool.hh"

#include <algorithm>
#include <thread>
#include <cstring>

#include <sys/types.h>
#include <sys/wait.h>

using namespace nix;

struct Evaluator
{
    nix::Pool<Connection> dbPool;

    typedef std::pair<std::string, std::string> JobsetName;

    struct Jobset
    {
        JobsetName name;
        time_t lastCheckedTime, triggerTime;
        int checkInterval;
        Pid pid;
    };

    typedef std::map<JobsetName, Jobset> Jobsets;

    int evalTimeout = 3600;

    size_t maxEvals = 4;

    struct State
    {
        size_t runningEvals = 0;
        Jobsets jobsets;
    };

    Sync<State> state_;

    std::condition_variable childStarted;
    std::condition_variable maybeDoWork;

    const time_t notTriggered = std::numeric_limits<time_t>::max();

    void readJobsets()
    {
        auto conn(dbPool.get());

        pqxx::work txn(*conn);

        auto res = txn.parameterized
            ("select project, j.name, lastCheckedTime, triggerTime, checkInterval from Jobsets j join Projects p on j.project = p.name "
             "where j.enabled != 0 and p.enabled != 0").exec();

        auto state(state_.lock());

        std::set<JobsetName> seen;

        for (auto const & row : res) {
            auto name = JobsetName{row["project"].as<std::string>(), row["name"].as<std::string>()};

            auto res = state->jobsets.try_emplace(name, Jobset{name});

            auto & jobset = res.first->second;
            jobset.lastCheckedTime = row["lastCheckedTime"].as<time_t>(0);
            jobset.triggerTime = row["triggerTime"].as<time_t>(notTriggered);
            jobset.checkInterval = row["checkInterval"].as<time_t>();

            seen.insert(name);
        }

        for (auto i = state->jobsets.begin(); i != state->jobsets.end(); )
            if (seen.count(i->first))
                ++i;
            else {
                printInfo("forgetting jobset ‘%s:%s’", i->first.first, i->first.second);
                i = state->jobsets.erase(i);
            }
    }

    void startEval(State & state, Jobset & jobset)
    {
        printInfo("starting evaluation of jobset ‘%s:%s’", jobset.name.first, jobset.name.second);

        assert(jobset.pid == -1);

        jobset.pid = startProcess([&]() {
            Strings args = { "timeout", "-s", "KILL", std::to_string(evalTimeout), "hydra-eval-jobset", jobset.name.first, jobset.name.second };
            execvp(args.front().c_str(), stringsToCharPtrs(args).data());
            throw SysError(format("executing ‘%1%’") % args.front());
        });

        state.runningEvals++;

        childStarted.notify_one();

        time_t now = time(0);

        {
            auto conn(dbPool.get());
            pqxx::work txn(*conn);
            txn.parameterized
                ("update Jobsets set lastCheckedTime = $1, triggerTime = null where project = $2 and name = $3")
                (now)
                (jobset.name.first)
                (jobset.name.second)
                .exec();
            txn.commit();

            jobset.lastCheckedTime = now;
            jobset.triggerTime = notTriggered;
        }
    }

    void startEvals(State & state)
    {
        std::vector<Jobsets::iterator> sorted;

        time_t now = time(0);

        /* Filter out jobsets that have been evaluated recently and have
           not been triggered. */
        for (auto i = state.jobsets.begin(); i != state.jobsets.end(); ++i)
            if (i->second.pid == -1 &&
                (i->second.triggerTime != std::numeric_limits<time_t>::max() ||
                    (i->second.checkInterval > 0 && i->second.lastCheckedTime + i->second.checkInterval <= now)))
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
                for (auto & jobset : state->jobsets)
                    if (jobset.second.pid == pid) {
                        printInfo("evaluation of jobset ‘%s:%s’ %s",
                            jobset.first.first, jobset.first.second, statusToString(status));
                        jobset.second.pid.release();
                        maybeDoWork.notify_one();
                        break;
                    }
            }
        }
    }

    void run()
    {
        std::thread reaperThread([&]() { reaper(); });

        std::thread monitorThread([&]() { databaseMonitor(); });

        while (true) {
            try {
                loop();
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

        parseCmdLine(argc, argv, [&](Strings::iterator & arg, const Strings::iterator & end) {
            return false;
        });

        Evaluator().run();
    });
}

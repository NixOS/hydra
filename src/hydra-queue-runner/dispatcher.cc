#include <algorithm>
#include <cmath>
#include <thread>
#include <unordered_map>

#include "state.hh"

using namespace nix;


void State::makeRunnable(Step::ptr step)
{
    printMsg(lvlChatty, format("step ‘%1%’ is now runnable") % step->drvPath);

    {
        auto step_(step->state.lock());
        assert(step_->created);
        assert(!step->finished);
        assert(step_->deps.empty());
        step_->runnableSince = std::chrono::system_clock::now();
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

        try {
            printMsg(lvlDebug, "dispatcher woken up");
            nrDispatcherWakeups++;

            auto now1 = std::chrono::steady_clock::now();

            auto sleepUntil = doDispatch();

            auto now2 = std::chrono::steady_clock::now();

            dispatchTimeMs += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();

            /* Sleep until we're woken up (either because a runnable build
               is added, or because a build finishes). */
            {
                auto dispatcherWakeup_(dispatcherWakeup.lock());
                if (!*dispatcherWakeup_) {
                    printMsg(lvlDebug, format("dispatcher sleeping for %1%s") %
                        std::chrono::duration_cast<std::chrono::seconds>(sleepUntil - std::chrono::system_clock::now()).count());
                    dispatcherWakeup_.wait_until(dispatcherWakeupCV, sleepUntil);
                }
                *dispatcherWakeup_ = false;
            }

        } catch (std::exception & e) {
            printMsg(lvlError, format("dispatcher: %1%") % e.what());
            sleep(1);
        }

    }

    printMsg(lvlError, "dispatcher exits");
}


system_time State::doDispatch()
{
    /* Prune old historical build step info from the jobsets. */
    {
        auto jobsets_(jobsets.lock());
        for (auto & jobset : *jobsets_) {
            auto s1 = jobset.second->shareUsed();
            jobset.second->pruneSteps();
            auto s2 = jobset.second->shareUsed();
            if (s1 != s2)
                printMsg(lvlDebug, format("pruned scheduling window of ‘%1%:%2%’ from %3% to %4%")
                    % jobset.first.first % jobset.first.second % s1 % s2);
        }
    }

    /* Start steps until we're out of steps or slots. */
    auto sleepUntil = system_time::max();
    bool keepGoing;

    do {
        system_time now = std::chrono::system_clock::now();

        /* Copy the currentJobs field of each machine. This is
           necessary to ensure that the sort comparator below is
           an ordering. std::sort() can segfault if it isn't. Also
           filter out temporarily disabled machines. */
        struct MachineInfo
        {
            Machine::ptr machine;
            unsigned long currentJobs;
        };
        std::vector<MachineInfo> machinesSorted;
        {
            auto machines_(machines.lock());
            for (auto & m : *machines_) {
                auto info(m.second->state->connectInfo.lock());
                if (!m.second->enabled) continue;
                if (info->consecutiveFailures && info->disabledUntil > now) {
                    if (info->disabledUntil < sleepUntil)
                        sleepUntil = info->disabledUntil;
                    continue;
                }
                machinesSorted.push_back({m.second, m.second->state->currentJobs});
            }
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
                float ta = std::round(a.currentJobs / a.machine->speedFactor);
                float tb = std::round(b.currentJobs / b.machine->speedFactor);
                return
                    ta != tb ? ta < tb :
                    a.machine->speedFactor != b.machine->speedFactor ? a.machine->speedFactor > b.machine->speedFactor :
                    a.currentJobs > b.currentJobs;
            });

        /* Sort the runnable steps by priority. Priority is establised
           as follows (in order of precedence):

           - The global priority of the builds that depend on the
             step. This allows admins to bump a build to the front of
             the queue.

           - The lowest used scheduling share of the jobsets depending
             on the step.

           - The local priority of the build, as set via the build's
             meta.schedulingPriority field. Note that this is not
             quite correct: the local priority should only be used to
             establish priority between builds in the same jobset, but
             here it's used between steps in different jobsets if they
             happen to have the same lowest used scheduling share. But
             that's not very likely.

           - The lowest ID of the builds depending on the step;
             i.e. older builds take priority over new ones.

           FIXME: O(n lg n); obviously, it would be better to keep a
           runnable queue sorted by priority. */
        struct StepInfo
        {
            Step::ptr step;

            /* The lowest share used of any jobset depending on this
               step. */
            double lowestShareUsed = 1e9;

            /* Info copied from step->state to ensure that the
               comparator is a partial ordering (see MachineInfo). */
            int highestGlobalPriority;
            int highestLocalPriority;
            BuildID lowestBuildID;

            StepInfo(Step::ptr step, Step::State & step_) : step(step)
            {
                for (auto & jobset : step_.jobsets)
                    lowestShareUsed = std::min(lowestShareUsed, jobset->shareUsed());
                highestGlobalPriority = step_.highestGlobalPriority;
                highestLocalPriority = step_.highestLocalPriority;
                lowestBuildID = step_.lowestBuildID;
            }
        };

        std::vector<StepInfo> runnableSorted;

        struct RunnablePerType
        {
            unsigned int count{0};
            std::chrono::seconds waitTime{0};
        };

        std::unordered_map<std::string, RunnablePerType> runnablePerType;

        {
            auto runnable_(runnable.lock());
            runnableSorted.reserve(runnable_->size());
            for (auto i = runnable_->begin(); i != runnable_->end(); ) {
                auto step = i->lock();

                /* Remove dead steps. */
                if (!step) {
                    i = runnable_->erase(i);
                    continue;
                }

                ++i;

                auto & r = runnablePerType[step->systemType];
                r.count++;

                /* Skip previously failed steps that aren't ready
                   to be retried. */
                auto step_(step->state.lock());
                r.waitTime += std::chrono::duration_cast<std::chrono::seconds>(now - step_->runnableSince);
                if (step_->tries > 0 && step_->after > now) {
                    if (step_->after < sleepUntil)
                        sleepUntil = step_->after;
                    continue;
                }

                runnableSorted.emplace_back(step, *step_);
            }
        }

        sort(runnableSorted.begin(), runnableSorted.end(),
            [](const StepInfo & a, const StepInfo & b)
            {
                return
                    a.highestGlobalPriority != b.highestGlobalPriority ? a.highestGlobalPriority > b.highestGlobalPriority :
                    a.lowestShareUsed != b.lowestShareUsed ? a.lowestShareUsed < b.lowestShareUsed :
                    a.highestLocalPriority != b.highestLocalPriority ? a.highestLocalPriority > b.highestLocalPriority :
                    a.lowestBuildID < b.lowestBuildID;
            });

        /* Find a machine with a free slot and find a step to run
           on it. Once we find such a pair, we restart the outer
           loop because the machine sorting will have changed. */
        keepGoing = false;

        std::vector<Machine::ptr> busyMachines;

        for (auto & mi : machinesSorted) {
            if (mi.machine->state->currentJobs >= mi.machine->maxJobs) {
                busyMachines.push_back(mi.machine);
                continue;
            }

            for (auto & stepInfo : runnableSorted) {
                auto & step(stepInfo.step);

                /* Can this machine do this step? */
                if (!mi.machine->supportsStep(step)) {
                    debug("machine '%s' does not support step '%s' (system type '%s')",
                        mi.machine->sshName, step->drvPath, step->drv.platform);
                    continue;
                }

                /* Let's do this step. Remove it from the runnable
                   list. FIXME: O(n). */
                {
                    auto runnable_(runnable.lock());
                    bool removed = false;
                    for (auto i = runnable_->begin(); i != runnable_->end(); )
                        if (i->lock() == step) {
                            i = runnable_->erase(i);
                            removed = true;
                            break;
                        } else ++i;
                    assert(removed);
                    auto & r = runnablePerType[step->systemType];
                    assert(r.count);
                    r.count--;
                }

                /* Make a slot reservation and start a thread to
                   do the build. */
                auto builderThread = std::thread(&State::builder, this,
                    std::make_shared<MachineReservation>(*this, step, mi.machine));
                builderThread.detach(); // FIXME?

                keepGoing = true;
                break;
            }

            if (keepGoing) break;
        }

        for (auto & stepInfo : runnableSorted) {
            auto & step(stepInfo.step);
            bool couldRunStep = false;
            for (auto & mp : busyMachines)
                if (mp->supportsStep(step)) {
                    couldRunStep = true;
                    break;
                }
            if (couldRunStep) continue;
            printMsg(lvlError, format("NO MACHINE AVAILABLE to run step '%1%' (needs system type '%2%')") %
                     step->drvPath % step->systemType);
        }

        /* Update the stats for the auto-scaler. */
        {
            auto machineTypes_(machineTypes.lock());

            for (auto & i : *machineTypes_)
                i.second.runnable = 0;

            for (auto & i : runnablePerType) {
                auto & j = (*machineTypes_)[i.first];
                j.runnable = i.second.count;
                j.waitTime = i.second.waitTime;
            }
        }

        lastDispatcherCheck = std::chrono::system_clock::to_time_t(now);

    } while (keepGoing);

    return sleepUntil;
}


void State::wakeDispatcher()
{
    {
        auto dispatcherWakeup_(dispatcherWakeup.lock());
        *dispatcherWakeup_ = true;
    }
    dispatcherWakeupCV.notify_one();
}


void Jobset::addStep(time_t startTime, time_t duration)
{
    auto steps_(steps.lock());
    (*steps_)[startTime] = duration;
    seconds += duration;
}


void Jobset::pruneSteps()
{
    time_t now = time(0);
    auto steps_(steps.lock());
    while (!steps_->empty()) {
        auto i = steps_->begin();
        if (i->first > now - schedulingWindow) break;
        seconds -= i->second;
        steps_->erase(i);
    }
}


State::MachineReservation::MachineReservation(State & state, Step::ptr step, Machine::ptr machine)
    : state(state), step(step), machine(machine)
{
    machine->state->currentJobs++;

    {
        auto machineTypes_(state.machineTypes.lock());
        (*machineTypes_)[step->systemType].running++;
    }
}


State::MachineReservation::~MachineReservation()
{
    auto prev = machine->state->currentJobs--;
    assert(prev);
    if (prev == 1)
        machine->state->idleSince = time(0);

    {
        auto machineTypes_(state.machineTypes.lock());
        auto & machineType = (*machineTypes_)[step->systemType];
        assert(machineType.running);
        machineType.running--;
        if (machineType.running == 0)
            machineType.lastActive = std::chrono::system_clock::now();
    }
}

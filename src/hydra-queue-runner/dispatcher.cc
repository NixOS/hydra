#include <algorithm>
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

        auto sleepUntil = doDispatch();

        /* Sleep until we're woken up (either because a runnable build
           is added, or because a build finishes). */
        {
            auto dispatcherWakeup_(dispatcherWakeup.lock());
            if (!*dispatcherWakeup_) {
                printMsg(lvlDebug, format("dispatcher sleeping for %1%s") %
                    std::chrono::duration_cast<std::chrono::seconds>(sleepUntil - std::chrono::system_clock::now()).count());
                dispatcherWakeup_.wait_until(dispatcherWakeupCV, sleepUntil);
            }
            nrDispatcherWakeups++;
            *dispatcherWakeup_ = false;
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
            unsigned int currentJobs;
        };
        std::vector<MachineInfo> machinesSorted;
        {
            auto machines_(machines.lock());
            for (auto & m : *machines_) {
                auto info(m.second->state->connectInfo.lock());
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
                float ta = roundf(a.currentJobs / a.machine->speedFactor);
                float tb = roundf(b.currentJobs / b.machine->speedFactor);
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
             that's not every likely.

           - The lowest ID of the builds depending on the step;
             i.e. older builds take priority over new ones.

           FIXME: O(n lg n); obviously, it would be better to keep a
           runnable queue sorted by priority. */
        std::vector<Step::ptr> runnableSorted;
        std::unordered_map<std::string, unsigned int> runnablePerType;
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

                runnablePerType[step->drv.platform]++;

                /* Skip previously failed steps that aren't ready
                   to be retried. */
                {
                    auto step_(step->state.lock());
                    if (step_->tries > 0 && step_->after > now) {
                        if (step_->after < sleepUntil)
                            sleepUntil = step_->after;
                        continue;
                    }
                }

                runnableSorted.push_back(step);
            }
        }

        for (auto & step : runnableSorted) {
            auto step_(step->state.lock());
            step_->lowestShareUsed = 1e9;
            for (auto & jobset : step_->jobsets)
                step_->lowestShareUsed = std::min(step_->lowestShareUsed, jobset->shareUsed());
        }

        sort(runnableSorted.begin(), runnableSorted.end(),
            [](const Step::ptr & a, const Step::ptr & b)
            {
                auto a_(a->state.lock());
                auto b_(b->state.lock()); // FIXME: deadlock?
                return
                    a_->highestGlobalPriority != b_->highestGlobalPriority ? a_->highestGlobalPriority > b_->highestGlobalPriority :
                    a_->lowestShareUsed != b_->lowestShareUsed ? a_->lowestShareUsed < b_->lowestShareUsed :
                    a_->highestLocalPriority != b_->highestLocalPriority ? a_->highestLocalPriority > b_->highestLocalPriority :
                    a_->lowestBuildID < b_->lowestBuildID;
            });

        /* Find a machine with a free slot and find a step to run
           on it. Once we find such a pair, we restart the outer
           loop because the machine sorting will have changed. */
        keepGoing = false;

        for (auto & mi : machinesSorted) {
            if (mi.machine->state->currentJobs >= mi.machine->maxJobs) continue;

            for (auto & step : runnableSorted) {

                /* Can this machine do this step? */
                if (!mi.machine->supportsStep(step)) continue;

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
                    assert(runnablePerType[step->drv.platform]);
                    runnablePerType[step->drv.platform]--;
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

        /* Update the stats for the auto-scaler. */
        {
            auto machineTypes_(machineTypes.lock());

            for (auto & i : *machineTypes_)
                i.second.runnable = 0;

            for (auto & i : runnablePerType)
                (*machineTypes_)[i.first].runnable = i.second;
        }

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
        (*machineTypes_)[step->drv.platform].running++;
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
        auto & machineType = (*machineTypes_)[step->drv.platform];
        assert(machineType.running);
        machineType.running--;
        if (machineType.running == 0)
            machineType.lastActive = time(0);
    }
}

#include "build-result.hh"
#include "serve-protocol.hh"
#include "state.hh"
#include "current-process.hh"
#include "processes.hh"
#include "util.hh"
#include "finally.hh"
#include "url.hh"
#include "worker-protocol.hh"

using namespace nix;

static std::string machineToStoreUrl(Machine::ptr machine)
{
    if (machine->sshName == "localhost")
        return "auto";

    // FIXME: remove this, rely on Machine::Machine(), Machine::openStore().

    // SSH flags: "-oBatchMode=yes", "-oConnectTimeout=60", "-oTCPKeepAlive=yes"

    return "ssh://" + machine->sshName;
}

void State::buildRemote(ref<Store> destStore,
    Machine::ptr machine, Step::ptr step,
    unsigned int maxSilentTime, unsigned int buildTimeout, unsigned int repeats,
    RemoteResult & result, std::shared_ptr<ActiveStep> activeStep,
    std::function<void(StepState)> updateStep,
    NarMemberDatas & narMembers)
{
    assert(BuildResult::TimedOut == 8);

    std::string base(step->drvPath.to_string());
    result.logFile = logDir + "/" + std::string(base, 0, 2) + "/" + std::string(base, 2);

    createDirs(dirOf(result.logFile));

    try {

        updateStep(ssBuilding);
        result.startTime = time(0);

        auto buildStoreUrl = machineToStoreUrl(machine);

        Strings args = {
            localStore->printStorePath(step->drvPath),
            "--store", destStore->getUri(),
            "--eval-store", localStore->getUri(),
            "--build-store", buildStoreUrl,
            "--max-silent-time", std::to_string(maxSilentTime),
            "--timeout", std::to_string(buildTimeout),
            "--max-build-log-size", std::to_string(maxLogSize),
            "--max-output-size", std::to_string(maxOutputSize),
            "--repeat", std::to_string(repeats),
            "--log-file", result.logFile,
            // FIXME: step->isDeterministic
        };

        // FIXME: set pid for cancellation

        auto [status, childStdout] = [&]() {
            MaintainCount<counter> mc(nrStepsBuilding);
            return runProgram({
                .program = "hydra-build-step",
                .args = std::move(args),
            });
        }();

        #if 0
        {
            auto activeStepState(activeStep->state_.lock());
            if (activeStepState->cancelled) throw Error("step cancelled");
            activeStepState->pid = child.pid;
        }

        Finally clearPid([&]() {
            auto activeStepState(activeStep->state_.lock());
            activeStepState->pid = -1;

            /* FIXME: there is a slight race here with step
               cancellation in State::processQueueChange(), which
               could call kill() on this pid after we've done waitpid()
               on it. With pid wrap-around, there is a tiny
               possibility that we end up killing another
               process. Meh. */
        });
        #endif

        result.stopTime = time(0);

        if (!statusOk(status))
            throw ExecError(status, fmt("hydra-build-step %s with output:\n%s", statusToString(status), stdout));

        /* The build was executed successfully, so clear the failure
           count for this machine. */
        {
            auto info(machine->state->connectInfo.lock());
            info->consecutiveFailures = 0;
        }

        StringSource from { childStdout };
        /* Read the BuildResult from the child. */
        WorkerProto::ReadConn rconn {
            .from = from,
            // Hardcode latest version because we are deploying hydra
            // itself atomically
            .version = PROTOCOL_VERSION,
        };
        result.overhead += readNum<uint64_t>(rconn.from);
        auto totalNarSize = readNum<uint64_t>(rconn.from);
        auto buildResult = WorkerProto::Serialise<BuildResult>::read(*localStore, rconn);

        // FIXME: make RemoteResult inherit BuildResult.
        result.errorMsg = buildResult.errorMsg;
        result.timesBuilt = buildResult.timesBuilt;
        result.isNonDeterministic = buildResult.isNonDeterministic;
        if (buildResult.startTime && buildResult.stopTime) {
            result.startTime = buildResult.startTime;
            result.stopTime = buildResult.stopTime;
        }

        switch (buildResult.status) {
            case BuildResult::Built:
                result.stepStatus = bsSuccess;
                break;
            case BuildResult::Substituted:
            case BuildResult::AlreadyValid:
                result.stepStatus = bsSuccess;
                result.isCached = true;
                break;
            case BuildResult::PermanentFailure:
                result.stepStatus = bsFailed;
                result.canCache = true;
                result.errorMsg = "";
                break;
            case BuildResult::InputRejected:
            case BuildResult::OutputRejected:
                result.stepStatus = bsFailed;
                result.canCache = true;
                break;
            case BuildResult::TransientFailure:
                result.stepStatus = bsFailed;
                result.canRetry = true;
                result.errorMsg = "";
                break;
            case BuildResult::TimedOut:
                result.stepStatus = bsTimedOut;
                result.errorMsg = "";
                break;
            case BuildResult::MiscFailure:
                result.stepStatus = bsAborted;
                result.canRetry = true;
                break;
            case BuildResult::LogLimitExceeded:
                result.stepStatus = bsLogLimitExceeded;
                break;
            case BuildResult::NotDeterministic:
                result.stepStatus = bsNotDeterministic;
                result.canRetry = false;
                result.canCache = true;
                break;
            default:
                result.stepStatus = bsAborted;
                break;
        }

        if (result.stepStatus != bsSuccess) return;

        result.errorMsg = "";

        /* If the NAR size limit was exceeded, then hydra-build-step
           will not have copied the output paths. */
        if (totalNarSize > maxOutputSize) {
            result.stepStatus = bsNarSizeLimitExceeded;
            return;
        }

        /* If the path was substituted or already valid, then we didn't
           get a build log. */
        if (result.isCached) {
            printMsg(lvlInfo, "outputs of ‘%s’ substituted or already valid on ‘%s’",
                localStore->printStorePath(step->drvPath), machine->sshName);
            unlink(result.logFile.c_str());
            result.logFile = "";
        }

    } catch (Error & e) {
        /* Disable this machine until a certain period of time has
           passed. This period increases on every consecutive
           failure. However, don't count failures that occurred soon
           after the last one (to take into account steps started in
           parallel). */
        auto info(machine->state->connectInfo.lock());
        auto now = std::chrono::system_clock::now();
        if (info->consecutiveFailures == 0 || info->lastFailure < now - std::chrono::seconds(30)) {
            info->consecutiveFailures = std::min(info->consecutiveFailures + 1, (unsigned int) 4);
            info->lastFailure = now;
            int delta = retryInterval * std::pow(retryBackoff, info->consecutiveFailures - 1) + (rand() % 30);
            printMsg(lvlInfo, "will disable machine ‘%1%’ for %2%s", machine->sshName, delta);
            info->disabledUntil = now + std::chrono::seconds(delta);
        }
        throw;
    }
}

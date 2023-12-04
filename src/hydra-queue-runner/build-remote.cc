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

namespace nix::build_remote {

static Path createLogFileDir(const std::string & logDir, const StorePath & drvPath)
{
    std::string base(drvPath.to_string());
    auto logFile = logDir + "/" + std::string(base, 0, 2) + "/" + std::string(base, 2);

    createDirs(dirOf(logFile));

    return logFile;
}

}

/* using namespace nix::build_remote; */

void RemoteResult::updateWithBuildResult(const nix::BuildResult & buildResult)
{
    RemoteResult thisArrow;

    // FIXME: make RemoteResult inherit BuildResult.
    timesBuilt = buildResult.timesBuilt;
    errorMsg = buildResult.errorMsg;
    isNonDeterministic = buildResult.isNonDeterministic;
    if (buildResult.startTime && buildResult.stopTime) {
        startTime = buildResult.startTime;
        stopTime = buildResult.stopTime;
    }

    switch ((BuildResult::Status) buildResult.status) {
        case BuildResult::Built:
            stepStatus = bsSuccess;
            break;
        case BuildResult::Substituted:
        case BuildResult::AlreadyValid:
            stepStatus = bsSuccess;
            isCached = true;
            break;
        case BuildResult::PermanentFailure:
            stepStatus = bsFailed;
            canCache = true;
            errorMsg = "";
            break;
        case BuildResult::InputRejected:
        case BuildResult::OutputRejected:
            stepStatus = bsFailed;
            canCache = true;
            break;
        case BuildResult::TransientFailure:
            stepStatus = bsFailed;
            canRetry = true;
            errorMsg = "";
            break;
        case BuildResult::TimedOut:
            stepStatus = bsTimedOut;
            errorMsg = "";
            break;
        case BuildResult::MiscFailure:
            stepStatus = bsAborted;
            canRetry = true;
            break;
        case BuildResult::LogLimitExceeded:
            stepStatus = bsLogLimitExceeded;
            break;
        case BuildResult::NotDeterministic:
            stepStatus = bsNotDeterministic;
            canRetry = false;
            canCache = true;
            break;
        default:
            stepStatus = bsAborted;
            break;
    }

}


void State::buildRemote(ref<Store> destStore,
    Machine::ptr machine, Step::ptr step,
    const BuildOptions & buildOptions,
    RemoteResult & result, std::shared_ptr<ActiveStep> activeStep,
    std::function<void(StepState)> updateStep,
    NarMemberDatas & narMembers)
{
    assert(BuildResult::TimedOut == 8);

    result.logFile = build_remote::createLogFileDir(logDir, step->drvPath);

    try {

        updateStep(ssBuilding);
        result.startTime = time(0);

        auto buildStoreUrl = machineToStoreUrl(machine);

        Strings args = {
            localStore->printStorePath(step->drvPath),
            "--store", destStore->getUri(),
            "--eval-store", localStore->getUri(),
            "--build-store", buildStoreUrl,
            "--max-silent-time", std::to_string(buildOptions.maxSilentTime),
            "--timeout", std::to_string(buildOptions.buildTimeout),
            "--max-build-log-size", std::to_string(buildOptions.maxLogSize),
            "--max-output-size", std::to_string(maxOutputSize),
            "--repeat", std::to_string(buildOptions.repeats),
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


        result.updateWithBuildResult(buildResult);

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

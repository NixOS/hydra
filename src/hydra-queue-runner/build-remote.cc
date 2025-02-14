#include <algorithm>
#include <cmath>

#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>

#include "build-result.hh"
#include "path.hh"
#include "legacy-ssh-store.hh"
#include "serve-protocol.hh"
#include "state.hh"
#include "current-process.hh"
#include "processes.hh"
#include "util.hh"
#include "ssh.hh"
#include "finally.hh"
#include "url.hh"

using namespace nix;

bool ::Machine::isLocalhost() const
{
    return storeUri.params.empty() && std::visit(overloaded {
        [](const StoreReference::Auto &) {
            return true;
        },
        [](const StoreReference::Specified & s) {
            return
               (s.scheme == "local" || s.scheme == "unix") ||
               ((s.scheme == "ssh" || s.scheme == "ssh-ng") &&
                s.authority == "localhost");
        },
    }, storeUri.variant);
}

namespace nix::build_remote {

static std::pair<Path, AutoCloseFD> openLogFile(const std::string & logDir, const StorePath & drvPath)
{
    std::string base(drvPath.to_string());
    auto logFile = logDir + "/" + std::string(base, 0, 2) + "/" + std::string(base, 2);

    createDirs(dirOf(logFile));

    AutoCloseFD logFD = open(logFile.c_str(), O_CREAT | O_TRUNC | O_WRONLY, 0666);
    if (!logFD) throw SysError("creating log file ‘%s’", logFile);

    return {std::move(logFile), std::move(logFD)};
}

static BasicDerivation sendInputs(
    State & state,
    Step & step,
    Store & localStore,
    Store & destStore,
    ::Machine::Connection & conn,
    unsigned int & overhead,
    counter & nrStepsWaiting,
    counter & nrStepsCopyingTo
)
{
    /* Replace the input derivations by their output paths to send a
       minimal closure to the builder.

       `tryResolve` currently does *not* rewrite input addresses, so it
       is safe to do this in all cases. (It should probably have a mode
       to do that, however, but we would not use it here.)
     */
    BasicDerivation basicDrv = ({
        auto maybeBasicDrv = step.drv->tryResolve(destStore, &localStore);
        if (!maybeBasicDrv)
            throw Error(
                "the derivation '%s' can’t be resolved. It’s probably "
                "missing some outputs",
                localStore.printStorePath(step.drvPath));
        *maybeBasicDrv;
    });

    /* Ensure that the inputs exist in the destination store. This is
       a no-op for regular stores, but for the binary cache store,
       this will copy the inputs to the binary cache from the local
       store. */
    if (&localStore != &destStore) {
        copyClosure(localStore, destStore,
            step.drv->inputSrcs,
            NoRepair, NoCheckSigs, NoSubstitute);
    }

    {
        auto mc1 = std::make_shared<MaintainCount<counter>>(nrStepsWaiting);
        mc1.reset();
        MaintainCount<counter> mc2(nrStepsCopyingTo);

        printMsg(lvlDebug, "sending closure of ‘%s’ to ‘%s’",
            localStore.printStorePath(step.drvPath), conn.machine->storeUri.render());

        auto now1 = std::chrono::steady_clock::now();

        /* Copy the input closure. */
        copyClosure(
            destStore,
            conn.machine->isLocalhost() ? localStore : *conn.store,
            basicDrv.inputSrcs,
            NoRepair,
            NoCheckSigs,
            Substitute);

        auto now2 = std::chrono::steady_clock::now();

        overhead += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();
    }

    return basicDrv;
}

static BuildResult performBuild(
    ::Machine::Connection & conn,
    Store & localStore,
    StorePath drvPath,
    const BasicDerivation & drv,
    const ServeProto::BuildOptions & options,
    counter & nrStepsBuilding
)
{
    auto kont = conn.store->buildDerivationAsync(drvPath, drv, options);

    BuildResult result;

    time_t startTime, stopTime;

    startTime = time(0);
    {
        MaintainCount<counter> mc(nrStepsBuilding);
        result = kont();
        // Without proper call-once functions, we need to manually
        // delete after calling.
        kont = {};
    }
    stopTime = time(0);

    if (!result.startTime) {
        // If the builder gave `startTime = 0`, use our measurements
        // instead of the builder's.
        //
        // Note: this represents the duration of a single round, rather
        // than all rounds.
        result.startTime = startTime;
        result.stopTime = stopTime;
    }

    // If the protocol was too old to give us `builtOutputs`, initialize
    // it manually by introspecting the derivation.
    if (GET_PROTOCOL_MINOR(conn.store->getProtocol()) < 6)
    {
        // If the remote is too old to handle CA derivations, we can’t get this
        // far anyways
        assert(drv.type().hasKnownOutputPaths());
        DerivationOutputsAndOptPaths drvOutputs = drv.outputsAndOptPaths(localStore);
        // Since this a `BasicDerivation`, `staticOutputHashes` will not
        // do any real work.
        auto outputHashes = staticOutputHashes(localStore, drv);
        for (auto & [outputName, output] : drvOutputs) {
            auto outputPath = output.second;
            // We’ve just asserted that the output paths of the derivation
            // were known
            assert(outputPath);
            auto outputHash = outputHashes.at(outputName);
            auto drvOutput = DrvOutput { outputHash, outputName };
            result.builtOutputs.insert_or_assign(
                std::move(outputName),
                Realisation { drvOutput, *outputPath });
        }
    }

    return result;
}

}

/* using namespace nix::build_remote; */

void RemoteResult::updateWithBuildResult(const nix::BuildResult & buildResult)
{
    startTime = buildResult.startTime;
    stopTime = buildResult.stopTime;
    timesBuilt = buildResult.timesBuilt;
    errorMsg = buildResult.errorMsg;
    isNonDeterministic = buildResult.isNonDeterministic;

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
    ::Machine::ptr machine, Step::ptr step,
    const ServeProto::BuildOptions & buildOptions,
    RemoteResult & result, std::shared_ptr<ActiveStep> activeStep,
    std::function<void(StepState)> updateStep,
    NarMemberDatas & narMembers)
{
    assert(BuildResult::TimedOut == 8);

    auto [logFile, logFD] = build_remote::openLogFile(logDir, step->drvPath);
    AutoDelete logFileDel(logFile, false);
    result.logFile = logFile;

    try {

        updateStep(ssConnecting);

        // FIXME: rewrite to use Store.
        ::Machine::Connection conn {
            .machine = machine,
            .store = [&]{
                auto * pSpecified = std::get_if<StoreReference::Specified>(&machine->storeUri.variant);
                if (!pSpecified || pSpecified->scheme != "ssh") {
                    throw Error("Currently, only (legacy-)ssh stores are supported!");
                }

                auto remoteStore = machine->openStore().dynamic_pointer_cast<LegacySSHStore>();
                assert(remoteStore);

                remoteStore->connPipeSize = 1024 * 1024;

                if (machine->isLocalhost()) {
                    auto rp_new = remoteStore->remoteProgram.get();
                    rp_new.push_back("--builders");
                    rp_new.push_back("");
                    const_cast<nix::Setting<Strings> &>(remoteStore->remoteProgram).assign(rp_new);
                }
                remoteStore->extraSshArgs = {
                    "-a", "-oBatchMode=yes", "-oConnectTimeout=60", "-oTCPKeepAlive=yes"
                };
                const_cast<nix::Setting<int> &>(remoteStore->logFD).assign(logFD.get());

                return nix::ref{remoteStore};
            }(),
        };

        {
            auto activeStepState(activeStep->state_.lock());
            if (activeStepState->cancelled) throw Error("step cancelled");
            activeStepState->pid = conn.store->getConnectionPid();
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

        Finally updateStats([&]() {
            auto stats = conn.store->getConnectionStats();
            bytesReceived += stats.bytesReceived;
            bytesSent += stats.bytesSent;
        });

        {
            auto info(machine->state->connectInfo.lock());
            info->consecutiveFailures = 0;
        }

        /* Gather the inputs. If the remote side is Nix <= 1.9, we have to
           copy the entire closure of ‘drvPath’, as well as the required
           outputs of the input derivations. On Nix > 1.9, we only need to
           copy the immediate sources of the derivation and the required
           outputs of the input derivations. */
        updateStep(ssSendingInputs);
        BasicDerivation resolvedDrv = build_remote::sendInputs(*this, *step, *localStore, *destStore, conn, result.overhead, nrStepsWaiting, nrStepsCopyingTo);

        logFileDel.cancel();

        /* Truncate the log to get rid of messages about substitutions
            etc. on the remote system. */
        if (lseek(logFD.get(), SEEK_SET, 0) != 0)
            throw SysError("seeking to the start of log file ‘%s’", result.logFile);

        if (ftruncate(logFD.get(), 0) == -1)
            throw SysError("truncating log file ‘%s’", result.logFile);

        logFD = -1;

        /* Do the build. */
        printMsg(lvlDebug, "building ‘%s’ on ‘%s’",
            localStore->printStorePath(step->drvPath),
            machine->storeUri.render());

        updateStep(ssBuilding);

        BuildResult buildResult = build_remote::performBuild(
            conn,
            *localStore,
            step->drvPath,
            resolvedDrv,
            buildOptions,
            nrStepsBuilding
        );

        result.updateWithBuildResult(buildResult);

        if (result.stepStatus != bsSuccess) return;

        result.errorMsg = "";

        /* If the path was substituted or already valid, then we didn't
           get a build log. */
        if (result.isCached) {
            printMsg(lvlInfo, "outputs of ‘%s’ substituted or already valid on ‘%s’",
                localStore->printStorePath(step->drvPath), machine->storeUri.render());
            unlink(result.logFile.c_str());
            result.logFile = "";
        }

        StorePathSet outputs;
        for (auto & [_, realisation] : buildResult.builtOutputs)
            outputs.insert(realisation.outPath);

        /* Copy the output paths. */
        if (!machine->isLocalhost() || localStore != std::shared_ptr<Store>(destStore)) {
            updateStep(ssReceivingOutputs);

            MaintainCount<counter> mc(nrStepsCopyingFrom);

            auto now1 = std::chrono::steady_clock::now();

            /* Copy each path. */
            printMsg(lvlDebug, "copying outputs of ‘%s’ from ‘%s’",
                localStore->printStorePath(step->drvPath), machine->storeUri.render());

            copyClosure(*conn.store, *destStore, outputs);

            auto now2 = std::chrono::steady_clock::now();

            result.overhead += std::chrono::duration_cast<std::chrono::milliseconds>(now2 - now1).count();
        }

        /* Register the outputs of the newly built drv */
        if (experimentalFeatureSettings.isEnabled(Xp::CaDerivations)) {
            auto outputHashes = staticOutputHashes(*localStore, *step->drv);
            for (auto & [outputName, realisation] : buildResult.builtOutputs) {
                // Register the resolved drv output
                destStore->registerDrvOutput(realisation);

                // Also register the unresolved one
                auto unresolvedRealisation = realisation;
                unresolvedRealisation.signatures.clear();
                unresolvedRealisation.id.drvHash = outputHashes.at(outputName);
                destStore->registerDrvOutput(unresolvedRealisation);
            }
        }

        /* Shut down the connection done by RAII.

           Only difference is kill() instead of wait() (i.e. send signal
           then wait())
         */

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
            printMsg(lvlInfo, "will disable machine ‘%1%’ for %2%s", machine->storeUri.render(), delta);
            info->disabledUntil = now + std::chrono::seconds(delta);
        }
        throw;
    }
}

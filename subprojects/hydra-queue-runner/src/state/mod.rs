mod atomic;
mod build;
pub mod drv;
mod fod_checker;
mod inspectable_channel;
mod jobset;
mod machine;
mod metrics;
mod queue;
mod step;
mod step_info;
mod uploader;

pub use atomic::AtomicDateTime;

/// Errors from external subsystems, plus the combined state-logic errors
/// under [`Logic`](`Self::Logic`).
#[derive(Debug, thiserror::Error)]
pub enum StateError {
    #[error("database error")]
    Db(#[from] db::Error),

    #[error("I/O error")]
    Io(#[from] std::io::Error),

    #[error("nix daemon error")]
    Daemon(#[from] harmonia_store_remote::DaemonError),

    #[error("jobset error")]
    Jobset(#[from] jobset::JobsetError),

    #[error("build output error")]
    BuildOutput(#[from] build::BuildOutputError),

    #[error("machine error")]
    Machine(#[from] machine::MachineError),

    #[error("metrics error")]
    Metrics(#[from] prometheus::Error),

    #[error("configuration error")]
    Config(#[from] crate::config::ConfigError),

    #[error("binary cache error")]
    Cache(#[from] binary_cache::CacheError),

    #[error("integer conversion error")]
    IntConversion(#[from] std::num::TryFromIntError),

    #[error("time computation error")]
    Jiff(#[from] jiff::Error),

    #[error("invalid platform UTF-8: {0}")]
    InvalidPlatformUtf8(std::str::Utf8Error),

    #[error("failed to construct log path string")]
    LogPathNotUtf8,

    #[error("local nix database error")]
    LocalNixDb(#[from] sqlx::Error),

    #[error("local nix database is not available")]
    LocalNixDbUnavailable,

    #[error("reading derivation `{drv}`: {reason}")]
    ReadDerivation {
        drv: StorePath,
        reason: &'static str,
    },

    #[error("state logic error")]
    Logic(#[from] StateLogicError),
}

/// All state logic errors combined. Sub-enums are defined alongside
/// the `impl State` blocks that use them.
#[derive(Debug, thiserror::Error)]
pub enum StateLogicError {
    #[error(transparent)]
    Resolution(#[from] ResolutionError),
    #[error(transparent)]
    StepLookup(#[from] StepLookupError),
    #[error(transparent)]
    MachineLookup(#[from] MachineLookupError),
    #[error(transparent)]
    DrvLookup(#[from] DrvLookupError),
}

impl From<ResolutionError> for StateError {
    fn from(e: ResolutionError) -> Self {
        Self::Logic(StateLogicError::Resolution(e))
    }
}
impl From<StepLookupError> for StateError {
    fn from(e: StepLookupError) -> Self {
        Self::Logic(StateLogicError::StepLookup(e))
    }
}
impl From<MachineLookupError> for StateError {
    fn from(e: MachineLookupError) -> Self {
        Self::Logic(StateLogicError::MachineLookup(e))
    }
}
impl From<DrvLookupError> for StateError {
    fn from(e: DrvLookupError) -> Self {
        Self::Logic(StateLogicError::DrvLookup(e))
    }
}

pub use build::{Build, BuildOutput, BuildResultState, BuildTimings, Builds, RemoteBuild};
use harmonia_store_derivation::derivation::Derivation;
use harmonia_store_path::StorePath;
pub use jobset::{Jobset, JobsetID, Jobsets};
pub use machine::{Machine, Message as MachineMessage, Pressure, Stats as MachineStats};
pub use queue::{BuildQueueStats, Queues};
pub use step::{Step, Steps};
pub use step_info::StepInfo;

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};
use std::time::Instant;

use futures::TryStreamExt as _;
use hashbrown::{HashMap, HashSet};
use secrecy::ExposeSecret as _;

use db::models::{BuildID, BuildStatus};
use harmonia_store_derivation::derivation::DerivationOutput;
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_derivation::realisation::{DrvOutput, Realisation, UnkeyedRealisation};
use inspectable_channel::InspectableChannel;

use crate::config::{App, Cli};
use crate::state::build::get_mark_build_sccuess_data;
pub use crate::state::fod_checker::FodChecker;
use crate::state::machine::Machines;
use crate::utils::finish_build_step;

pub type System = String;
const MAX_CONCURRENT_BUILD_INJECTION: usize = 50;
const BUILD_STEP_LOCK_SHARDS: usize = 1024;

enum CreateStepResult {
    None,
    Valid(Arc<Step>),
    PreviousFailure(Arc<Step>),
}

/// Output availability as discovered by [`State::prefetch_step_facts`].
#[derive(Debug)]
enum OutputAvailability {
    /// All outputs are available where builders fetch their inputs from.
    Complete,
    /// All outputs are valid locally, but builders fetch their inputs from
    /// the remote binary cache (presigned uploads) and these paths are
    /// missing there. The step must not count as finished before the upload
    /// completed.
    PendingUpload(Vec<StorePath>),
    /// Outputs are missing; the step has to be built.
    Incomplete,
}

/// What the IO phase ([`State::prefetch_step_facts`]) learned about a
/// derivation, used by the synchronous [`attach_step`].
struct StepFacts {
    drv: Derivation,
    availability: OutputAvailability,
    previous_failure: bool,
}

enum AttachOutcome {
    Finished,
    PreviousFailure,
    /// Created but gated: the caller must schedule an upload of these paths
    /// and finish the step via [`complete_step`] once it is done.
    PendingUpload(Vec<StorePath>),
    Attached,
}

/// Mark a step finished and wake its reverse dependencies.
fn complete_step(step: &Arc<Step>) {
    step.set_finished(true);
    step.make_rdeps_runnable();
}

/// Synchronously attach a prefetched step to the in-memory step graph:
/// finished/failure marking, dep registration, created flag and runnability
/// all happen here, with no IO in between. Deps are inserted via
/// [`Step::add_dep_if_unfinished`], so a dep that finished since the
/// prefetch is never added and the step cannot get stuck waiting on it.
fn attach_step(
    step: &Arc<Step>,
    availability: OutputAvailability,
    previous_failure: bool,
    deps: Vec<Arc<Step>>,
    new_runnable: &mut HashSet<Arc<Step>>,
) -> AttachOutcome {
    if previous_failure {
        step.set_previous_failure(true);
        return AttachOutcome::PreviousFailure;
    }
    match availability {
        OutputAvailability::Complete => {
            complete_step(step);
            AttachOutcome::Finished
        }
        OutputAvailability::PendingUpload(paths) => {
            // No deps and not runnable: nothing to build, but rdeps must
            // wait for the upload before they may be dispatched.
            step.atomic_state.set_created(true);
            AttachOutcome::PendingUpload(paths)
        }
        OutputAvailability::Incomplete => {
            for dep in deps {
                if dep.get_previous_failure() {
                    continue;
                }
                step.add_dep_if_unfinished(dep);
            }
            step.atomic_state.set_created(true);
            if step.get_deps_size() == 0 {
                new_runnable.insert(step.clone());
            }
            AttachOutcome::Attached
        }
    }
}

enum RealiseStepResult {
    None,
    /// Created a new resolved `BuildStep`
    Resolved,
    Valid(Arc<Machine>),
    MaybeCancelled,
    CachedFailure,
}

struct ProcessedBuild {
    _id: BuildID,
    nr_added: Arc<AtomicI64>,
    new_runnable: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>>,
    elapsed: u64,
}

#[allow(missing_debug_implementations)]
pub enum RemoteStoreBackend {
    S3(binary_cache::S3BinaryCacheClient),
    /// A nix store reachable via `nix copy --to <uri>`.
    NixCopy(String),
}

#[allow(missing_debug_implementations)]
pub struct State {
    pub pool: harmonia_store_remote::ConnectionPool,
    /// Direct read-only access to the Nix `SQLite` database; `None` when the
    /// database cannot be opened (e.g. in tests without a real store).
    pub local_db: Option<crate::local_db::LocalNixDb>,
    pub remote_stores: parking_lot::RwLock<Vec<RemoteStoreBackend>>,
    pub config: App,
    pub cli: Cli,
    pub db: db::Database,

    pub machines: Machines,

    pub log_dir: std::path::PathBuf,

    pub builds: Builds,
    pub jobsets: Jobsets,
    pub steps: Steps,
    pub queues: Queues,

    /// In-memory mapping from unresolved CA drv path to resolved drv
    /// path. Used to translate drv paths before SQL output lookups,
    /// temporarily avoiding the need for a `resolvedDrvPath` column in
    /// the database.
    ///
    /// FIXME: Replace this with proper persisted column, so we don't have to re-resolve on
    /// restart.
    pub resolved_drv_map: parking_lot::RwLock<HashMap<StorePath, StorePath>>,

    pub fod_checker: Option<Arc<FodChecker>>,

    pub started_at: jiff::Timestamp,

    /// Per-build locks (sharded by build id) serializing build step
    /// inserts; the queue runner is the only writer of `buildsteps`, so
    /// stepnr allocation only needs in-process serialization.
    build_step_locks: [tokio::sync::Mutex<()>; BUILD_STEP_LOCK_SHARDS],

    pub metrics: metrics::PromMetrics,
    pub notify_dispatch: tokio::sync::Notify,
    pub uploader: Arc<uploader::Uploader>,
    /// Receiver for upload completions of steps gated on
    /// [`OutputAvailability::PendingUpload`]; consumed by
    /// [`State::start_upload_completion_loop`].
    upload_completion_rx:
        parking_lot::Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<StorePath>>>,

    /// Parsed nix daemon store config (for reconstructing URIs etc).
    pub nix_daemon_config: daemon_client_utils::NixDaemonStoreConfig,
    /// Physical store directory on disk (for chroot stores).
    /// Cached from `nix_daemon_config.real_store_dir()`.
    /// `None` means the logical store dir is the filesystem path.
    pub real_store_dir: Option<std::path::PathBuf>,
}

impl State {
    /// Resolve a store path to a filesystem path, accounting for chroot stores.
    fn real_path(&self, path: &StorePath) -> std::path::PathBuf {
        match &self.real_store_dir {
            Some(real) => real.join(path.to_string()),
            None => std::path::PathBuf::from(self.pool.store_dir().display(path).to_string()),
        }
    }

    /// Read and parse a `.drv` file from the store.
    async fn read_derivation(&self, drv_path: &StorePath) -> Result<Derivation, StateError> {
        let content = fs_err::tokio::read_to_string(self.real_path(drv_path)).await?;
        let drv_name_str = drv_path.name().to_string();
        let name = drv_name_str
            .strip_suffix(".drv")
            .ok_or_else(|| StateError::ReadDerivation {
                drv: drv_path.clone(),
                reason: "name does not end in `.drv`",
            })?
            .parse()
            .map_err(|_| StateError::ReadDerivation {
                drv: drv_path.clone(),
                reason: "parsing derivation name",
            })?;
        harmonia_store_aterm::parse_derivation_aterm(
            self.pool.store_dir(),
            content.as_bytes(),
            name,
        )
        .map_err(|_| StateError::ReadDerivation {
            drv: drv_path.clone(),
            reason: "parsing derivation ATerm",
        })
    }

    #[tracing::instrument(err)]
    pub async fn new() -> Result<Arc<Self>, StateError> {
        let nix_config = daemon_client_utils::parse_nix_remote()
            .map_err(crate::config::ConfigError::ParseNixStore)?;
        let store_dir = nix_config.store_dir.clone();
        let pool = harmonia_store_remote::ConnectionPool::with_store_dir(
            &nix_config.socket,
            store_dir.clone(),
            harmonia_store_remote::PoolConfig::default(),
        );

        tracing::info!("LocalStore dir={store_dir}");

        let cli = Cli::new();

        let config = App::init(&cli.config_path)?;
        let log_dir = config.get_hydra_log_dir();
        let db = db::Database::new(
            config.get_db_url().expose_secret(),
            config.get_max_db_connections(),
        )
        .await?;

        match fs_err::tokio::create_dir_all(&log_dir).await {
            Ok(()) => tracing::info!("successfully created hydra log_dir={log_dir:?}"),
            Err(e) => tracing::error!("Failed to create hydra log_dir={log_dir:?} e={e}"),
        }

        let mut remote_stores = vec![];
        for uri in config.get_remote_store_addrs() {
            if let Ok(cfg) = uri.parse::<binary_cache::S3CacheConfig>() {
                remote_stores.push(RemoteStoreBackend::S3(
                    binary_cache::S3BinaryCacheClient::new(cfg).await?,
                ));
            } else {
                remote_stores.push(RemoteStoreBackend::NixCopy(uri.clone()));
            }
        }

        let fod_checker = if config.get_enable_fod_checker() {
            Some(Arc::new(FodChecker::new(pool.clone(), None)))
        } else {
            None
        };

        let (upload_completion_tx, upload_completion_rx) = tokio::sync::mpsc::unbounded_channel();

        let local_db = match crate::local_db::LocalNixDb::open(store_dir.clone()).await {
            Ok(db) => Some(db),
            Err(e) => {
                tracing::warn!(
                    "cannot open nix database read-only, falling back to daemon for read queries: {e}"
                );
                None
            }
        };

        Ok(Arc::new(Self {
            pool,
            local_db,
            remote_stores: parking_lot::RwLock::new(remote_stores),
            cli,
            db,
            machines: Machines::new(),
            resolved_drv_map: parking_lot::RwLock::new(HashMap::new()),
            log_dir,
            builds: Builds::new(),
            jobsets: Jobsets::new(),
            steps: Steps::new(),
            queues: Queues::new(),
            fod_checker,
            started_at: jiff::Timestamp::now(),
            build_step_locks: std::array::from_fn(|_| tokio::sync::Mutex::new(())),
            metrics: metrics::PromMetrics::new()?,
            notify_dispatch: tokio::sync::Notify::new(),
            uploader: Arc::new(
                uploader::Uploader::new(
                    config.get_hydra_data_dir().join("uploader_state.json"),
                    upload_completion_tx,
                )
                .await,
            ),
            upload_completion_rx: parking_lot::Mutex::new(Some(upload_completion_rx)),
            real_store_dir: nix_config.real_store_dir(),
            nix_daemon_config: nix_config,
            config,
        }))
    }

    #[tracing::instrument(skip(self, new_config), err)]
    pub async fn reload_config_callback(
        &self,
        new_config: &crate::config::PreparedApp,
    ) -> Result<(), StateError> {
        // IF this gets more complex we need a way to trap the state and revert.
        // right now it doesnt matter because only reconfigure_pool can fail and this is the first
        // thing we do.

        let curr_db_url = self.config.get_db_url();
        let curr_machine_sort_fn = self.config.get_machine_sort_fn();
        let curr_step_sort_fn = self.config.get_step_sort_fn();
        let curr_remote_stores = self.config.get_remote_store_addrs();
        let curr_enable_fod_checker = self.config.get_enable_fod_checker();
        let mut new_remote_stores = vec![];
        if curr_remote_stores != new_config.remote_store_addr {
            for uri in &new_config.remote_store_addr {
                if let Ok(cfg) = uri.parse::<binary_cache::S3CacheConfig>() {
                    new_remote_stores.push(RemoteStoreBackend::S3(
                        binary_cache::S3BinaryCacheClient::new(cfg).await?,
                    ));
                } else {
                    new_remote_stores.push(RemoteStoreBackend::NixCopy(uri.clone()));
                }
            }
        }

        if curr_db_url.expose_secret() != new_config.db_url.expose_secret() {
            self.db
                .reconfigure_pool(new_config.db_url.expose_secret())?;
        }
        if curr_machine_sort_fn != new_config.machine_sort_fn {
            self.machines.sort(new_config.machine_sort_fn);
        }
        if curr_step_sort_fn != new_config.step_sort_fn {
            self.queues.sort_queues(curr_step_sort_fn).await;
        }
        if curr_remote_stores != new_config.remote_store_addr {
            *self.remote_stores.write() = new_remote_stores;
        }

        if curr_enable_fod_checker != new_config.enable_fod_checker {
            tracing::warn!(
                "Changing the value of enable_fod_checker currently requires a restart!"
            );
        }

        self.machines
            .publish_new_config(machine::ConfigUpdate {
                max_concurrent_downloads: new_config.max_concurrent_downloads,
            })
            .await;

        Ok(())
    }

    #[tracing::instrument(skip(self, machine))]
    pub async fn insert_machine(&self, machine: Machine) -> uuid::Uuid {
        if !machine.systems.is_empty() {
            self.queues
                .ensure_queues_for_systems(&machine.systems)
                .await;
        }

        let machine_id = self
            .machines
            .insert_machine(machine, self.config.get_machine_sort_fn());
        self.trigger_dispatch();
        machine_id
    }

    #[tracing::instrument(skip(self))]
    pub async fn remove_machine(&self, machine_id: uuid::Uuid) {
        if let Some(m) = self.machines.remove_machine(machine_id) {
            let jobs = {
                let jobs = m.jobs.read();
                jobs.clone()
            };
            for job in &jobs {
                if let Err(e) = self
                    .fail_step(
                        machine_id,
                        &job.path,
                        // The machine went away (disconnect or shutdown); the
                        // step itself did not fail. Record Aborted, like
                        // clear_busy, and let the retry reschedule it.
                        BuildResultState::Aborted,
                        BuildTimings::default(),
                        None,
                    )
                    .await
                {
                    tracing::error!(
                        "Failed to fail step machine_id={machine_id} drv={} e={e}",
                        job.path
                    );
                }
            }
        }
    }

    pub async fn remove_all_machines(&self) {
        for m in self.machines.get_all_machines() {
            self.remove_machine(m.id).await;
        }
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn clear_busy(&self) -> Result<(), db::Error> {
        let mut db = self.db.get().await?;
        db.clear_busy(0).await?;
        Ok(())
    }
}

/// Errors from derivation resolution (CA floating, dynamic deps).
#[derive(Debug, thiserror::Error)]
pub enum ResolutionError {
    #[error("failed to resolve CAFloating derivation {0}")]
    UnresolvedCAFloating(StorePath),

    #[error("failed to resolve derivation {0}")]
    ResolveFailed(StorePath),

    #[error("failed to fill deferred outputs for {0}")]
    FillDeferredOutputs(StorePath),

    #[error("could not create resolved build step")]
    ResolvedStepCreationFailed,

    #[error("output path mismatch for output `{name}` of {drv}: expected {expected}, got {actual}")]
    OutputPathMismatch {
        name: String,
        drv: StorePath,
        expected: String,
        actual: String,
    },

    #[error("dynamic rdep references output `{output}` not produced by {drv}")]
    DynRdepOutputMissing { output: String, drv: StorePath },
}

impl State {
    #[tracing::instrument(skip(self, constraint), err)]
    #[allow(clippy::too_many_lines)]
    async fn realise_drv_on_valid_machine(
        self: Arc<Self>,
        constraint: queue::JobConstraint,
    ) -> Result<RealiseStepResult, StateError> {
        let free_fn = self.config.get_machine_free_fn();

        let Some((machine, step_info)) = constraint.resolve(&self.machines, free_fn) else {
            return Ok(RealiseStepResult::None);
        };
        let drv = step_info.step.get_drv_path();
        let default_max_log_size: u64 = 64 << 20; // 64 MiB
        // hydra-eval-jobs defaults for builds without meta.maxSilent/meta.timeout.
        const DEFAULT_MAX_SILENT_TIME: i32 = 3600;
        const DEFAULT_BUILD_TIMEOUT: i32 = 36000;
        let mut max_silent_time: i32;
        let mut build_timeout: i32;

        let build = {
            let mut dependents = HashSet::new();
            let mut steps = HashSet::new();
            step_info.step.get_dependents(&mut dependents, &mut steps);

            if dependents.is_empty() {
                // Apparently all builds that depend on this derivation are gone (e.g. cancelled). So
                // don't bother. This is very unlikely to happen, because normally Steps are only kept
                // alive by being reachable from a Build. However, it's possible that a new Build just
                // created a reference to this step. So to handle that possibility, we retry this step
                // (putting it back in the runnable queue). If there are really no strong pointers to
                // the step, it will be deleted.
                tracing::info!("maybe cancelling build step {drv}");
                return Ok(RealiseStepResult::MaybeCancelled);
            }

            let Some(build) = dependents
                .iter()
                .find(|b| &b.drv_path == drv)
                .or_else(|| dependents.iter().next())
            else {
                // this should never happen, as we checked is_empty above and fallback is just any build
                return Ok(RealiseStepResult::MaybeCancelled);
            };

            // We want the biggest timeout otherwise we could build a step like llvm with a timeout
            // of 180 because a nixostest with a timeout got scheduled and needs this step
            let biggest_max_silent_time = dependents.iter().map(|x| x.max_silent_time).max();
            let biggest_build_timeout = dependents.iter().map(|x| x.timeout).max();

            max_silent_time = biggest_max_silent_time.unwrap_or(build.max_silent_time);
            build_timeout = biggest_build_timeout.unwrap_or(build.timeout);

            // A build's meta.timeout describes its own derivation. When this
            // step is only a dependency of other builds (none has it as its
            // top-level), don't let their budgets cut below the hydra
            // defaults: a nixos test with meta.timeout = 180 must not limit
            // building its dependency closure on an empty binary cache.
            if !dependents.iter().any(|b| &b.drv_path == drv) {
                max_silent_time = max_silent_time.max(DEFAULT_MAX_SILENT_TIME);
                build_timeout = build_timeout.max(DEFAULT_BUILD_TIMEOUT);
            }
            build.clone()
        };

        let build_id = build.id;

        let mut job = machine::Job::new(build_id, drv.to_owned());
        job.result.set_start_time_now();
        if self.check_cached_failure(step_info.step.clone()).await {
            job.result.step_status = BuildStatus::CachedFailure;
            self.inner_fail_job(drv, None, job, step_info.step.clone())
                .await?;
            return Ok(RealiseStepResult::CachedFailure);
        }

        self.construct_log_file_path(drv)
            .await
            .clone_into(&mut job.result.log_file);
        let mut db = self.db.get().await?;
        let step_nr = {
            let _step_lock = self.build_step_lock(build_id).lock().await;
            let mut tx = db.begin_transaction().await?;

            let step_nr = tx
                .create_build_step(
                    self.pool.store_dir(),
                    Some(job.result.get_start_time_as_i32()?),
                    build_id,
                    step_info.step.get_drv_path(),
                    step_info.step.get_system().as_deref(),
                    machine.hostname.clone(),
                    BuildStatus::Busy,
                    None,
                    None,
                    step_info
                        .step
                        .get_output_paths()
                        .unwrap_or_default()
                        .into_iter()
                        .collect(),
                )
                .await?;

            tx.commit().await?;
            step_nr
        };
        job.step_nr = step_nr;

        // Resolve derivation inputs: replace `Built` input references with
        // concrete output store paths using `try_resolve_force`. For
        // input-addressed drvs this keeps the original output paths
        // (the "force" part); for CA floating drvs it doesn't matter
        // since there are no `InputAddressed` outputs. CA floating drvs
        // that resolve to a different drv path still need the two-phase
        // build dance.
        let (basic_drv, was_deferred) = {
            // Steps no longer keep the parsed derivation in memory; re-read it
            // from the local store now that the step is actually being realised.
            let Ok(full_drv) = self.read_derivation(drv).await else {
                return Ok(RealiseStepResult::MaybeCancelled);
            };
            let drv_ref = &full_drv;

            // Resolve `Built` input references to concrete store paths.
            let resolved_map = self.resolved_drv_map.read().clone();
            let mut basic_drv = StepInfo::try_resolve_force(
                self.pool.store_dir(),
                &self.db,
                drv_ref,
                &resolved_map,
            )
            .await
            .ok_or_else(|| ResolutionError::ResolveFailed(drv.clone()))?;

            // Input-addressed outputs that transitively depend on a CA
            // derivation come out of eval as `Deferred` because the IA
            // hash can't be computed until the CA dep's path is known.
            // Now that inputs are resolved, fill in the IA paths and
            // matching `$out` env vars via `fill_outputs`. The resolved
            // drv is then routed through the same two-phase dance as
            // CAFloating below so we can detect if resolution changed
            // the drv path.
            let was_deferred = !basic_drv.outputs.is_empty()
                && basic_drv
                    .outputs
                    .values()
                    .any(|o| matches!(o, DerivationOutput::Deferred));
            if was_deferred {
                let unfilled = basic_drv
                    .clone()
                    .map_outputs(|_| harmonia_store_aterm::input_address::UnfilledOutput);
                let filled = harmonia_store_aterm::input_address::fill_outputs(
                    self.pool.store_dir(),
                    unfilled,
                )
                .map_err(|_| ResolutionError::FillDeferredOutputs(drv.clone()))?;
                basic_drv = filled.map_outputs(DerivationOutput::InputAddressed);
            }
            (basic_drv, was_deferred)
        };

        // CA floating derivations and originally-Deferred derivations
        // both need a two-phase build: write the resolved drv to the
        // store via the daemon, get its assigned path, and (if it
        // differs from the original) dispatch a new step for it.
        if was_deferred
            || basic_drv
                .outputs
                .iter()
                .any(|o| matches!(o.1, DerivationOutput::CAFloating(_)))
        {
            // Write the resolved derivation to the store via daemon
            // protocol so we can compare its path.
            let resolved_path = {
                let mut guard = self.pool.acquire().await?;
                harmonia_protocol::daemon::write_derivation(
                    guard.client(),
                    self.pool.store_dir(),
                    &basic_drv,
                    false,
                )
                .await?
                .path
            };
            if &resolved_path != drv {
                tracing::info!("resolved CA derivation {drv} -> {resolved_path}");

                // Record the resolved drv path in memory so future
                // output lookups can translate through it.
                self.resolved_drv_map
                    .write()
                    .insert(drv.clone(), resolved_path.clone());

                // Finish original step as "resolved" in the DB and in-memory
                step_info.step.set_finished(true);
                let mut resolved_result = RemoteBuild::new();
                resolved_result.step_status = BuildStatus::Resolved;
                resolved_result.set_start_time_now();
                resolved_result.set_stop_time_now();
                resolved_result.log_file.clone_from(&job.result.log_file);
                finish_build_step(
                    &self.db,
                    self.pool.store_dir(),
                    build_id,
                    step_nr,
                    &resolved_result,
                    Some(&machine.hostname),
                    None,
                )
                .await?;

                // Only mark the resolved step as a direct build if the
                // unresolved step was the toplevel derivation of the build.
                // Otherwise, `succeed_step` would prematurely mark the build as
                // finished when an intermediate resolved step completes.
                let is_toplevel = build.toplevel.load().as_deref() == Some(&*step_info.step);
                let referring_build = if is_toplevel {
                    Some(build.clone())
                } else {
                    None
                };
                // Create a resolved in-memory step
                // We do not need the global state because they are only relevant when making
                // multiple steps. Our resolved step, by definition, has no dependencies, so
                // only one step will ever be created.
                // finished_drvs: A list of previously created steps within a build.
                // Without this, it is possible that we will make a duplicate step if two different
                // steps in the same build resolve to the same derivation, but it will not cause
                // problems.
                // new_steps: An output list of all created steps. Since only one is being made, the root,
                // we can take the return of the function.
                // new_runnable: An output list of the runnable steps. Again, only one will be made, so we
                // can take the function return.
                let resolved_step = match self
                    .create_step(
                        build.clone(),
                        resolved_path,
                        referring_build,
                        None,
                        Arc::new(parking_lot::RwLock::new(HashSet::new())),
                        Arc::new(parking_lot::RwLock::new(HashSet::new())),
                        Arc::new(parking_lot::RwLock::new(HashSet::new())),
                    )
                    .await
                {
                    CreateStepResult::None => {
                        return Err(StateError::from(
                            ResolutionError::ResolvedStepCreationFailed,
                        ));
                    }
                    CreateStepResult::Valid(step) => step,
                    CreateStepResult::PreviousFailure(step) => {
                        self.handle_previous_failure(build.clone(), step.clone())
                            .await?;
                        return Ok(RealiseStepResult::CachedFailure);
                    }
                };

                // Do not dispatch a resolved step that only waits for its
                // outputs to be uploaded; the upload completion wakes its
                // rdeps instead.
                if !resolved_step.get_finished() && !resolved_step.has_pending_upload() {
                    resolved_step.make_runnable();
                }

                // The in-memory `Arc<Step>` objects are kept alive by having a reference
                // from a `Build` (if they are the root build) or a dependant `Step`
                // (if they are not).
                // Therefore, we must prevent our new resolved step from being garbage
                // collected by marking it as a dependency of the old step's reverse
                // dependencies and, if it was the root derivation, as the new root
                // derivation of the build.

                // Replace the original step with the resolved step in the
                // dependency graph.  Each step that depended on the original
                // (unresolved) step must now depend on the resolved step
                // instead, otherwise it will never become runnable (the
                // original step's drv path differs from the resolved one, so
                // completing the resolved step wouldn't clear the dep).
                for rdep in step_info.step.clone_rdeps() {
                    if let Some(rdep) = rdep.step.upgrade() {
                        rdep.remove_dep(&step_info.step);
                        resolved_step.make_rdep(&rdep);
                    }
                }

                // Make the resolved step the new root of the build if the old
                // unresolved step was previously the root.
                if *build
                    .toplevel
                    .compare_and_swap(&step_info.step, Some(resolved_step))
                    == Some(step_info.step.clone())
                {
                    build.propagate_priorities();
                }

                // New steps runnable
                self.trigger_dispatch();

                // No more work to do, build will happen in another step
                return Ok(RealiseStepResult::Resolved);
            }
        }

        // Encode the force-resolved derivation as protobuf to send to the builder.
        let resolved_drv = hydra_proto::nix::store::derivation::v1::Basic::from(&basic_drv);

        {
            let mut tx = db.begin_transaction().await?;
            tx.notify_build_started(build_id).await?;
            tx.commit().await?;
        }
        tracing::info!(
            "Submitting build drv={drv} on machine={} hostname={} build_id={build_id} step_nr={}",
            machine.id,
            machine.hostname,
            job.step_nr,
        );
        self.db
            .get()
            .await?
            .update_build_step(db::models::UpdateBuildStep {
                build_id,
                step_nr: job.step_nr,
                status: db::models::StepStatus::Connecting,
            })
            .await?;
        machine
            .build_drv(
                job,
                drv.clone(),
                default_max_log_size,
                max_silent_time,
                build_timeout,
                // TODO: cleanup
                if self.config.use_presigned_uploads() {
                    let remote_stores = self.remote_stores.read();
                    remote_stores.iter().find_map(|s| match s {
                        RemoteStoreBackend::S3(s) => Some(hydra_proto::PresignedUploadOpts {
                            upload_debug_info: s.cfg.write_debug_info,
                        }),
                        RemoteStoreBackend::NixCopy(_) => None,
                    })
                } else {
                    None
                },
                resolved_drv,
            )
            .await?;
        self.metrics.nr_steps_started.inc();
        self.metrics.nr_steps_building.add(1);
        Ok(RealiseStepResult::Valid(machine))
    }

    #[tracing::instrument(skip(self), fields(%drv))]
    async fn construct_log_file_path(&self, drv: &StorePath) -> std::path::PathBuf {
        let mut log_file = self.log_dir.clone();
        let base = drv.to_string();
        let (dir, file) = base.split_at(2);
        log_file.push(format!("{dir}/"));
        if let Err(e) = fs_err::tokio::create_dir_all(&log_file).await {
            tracing::warn!("failed to create log directory {log_file:?}: {e}");
        }
        log_file.push(file);
        log_file
    }

    #[tracing::instrument(skip(self), fields(%drv), err)]
    pub async fn new_log_file(
        &self,
        drv: &StorePath,
    ) -> Result<fs_err::tokio::File, std::io::Error> {
        let log_file = self.construct_log_file_path(drv).await;
        tracing::debug!("opening {log_file:?}");

        fs_err::tokio::File::options()
            .create(true)
            .truncate(true)
            .write(true)
            .read(false)
            .mode(0o666)
            .open(log_file)
            .await
    }

    #[allow(clippy::cast_possible_truncation)]
    #[tracing::instrument(skip(self, new_builds_by_id, new_builds_by_path, finished_drvs), err)]
    async fn process_single_build(
        &self,
        id: BuildID,
        new_builds_by_id: Arc<parking_lot::RwLock<HashMap<BuildID, Arc<Build>>>>,
        new_builds_by_path: Arc<HashMap<StorePath, HashSet<BuildID>>>,
        finished_drvs: Arc<parking_lot::RwLock<HashSet<StorePath>>>,
    ) -> Result<Option<ProcessedBuild>, StateError> {
        let Some(build) = new_builds_by_id.read().get(&id).cloned() else {
            return Ok(None);
        };

        let new_runnable = Arc::new(parking_lot::RwLock::new(HashSet::<Arc<Step>>::new()));
        let nr_added: Arc<AtomicI64> = Arc::new(0.into());
        let now = Instant::now();

        self.create_build(
            build,
            nr_added.clone(),
            new_builds_by_id,
            new_builds_by_path,
            finished_drvs,
            new_runnable.clone(),
        )
        .await?;

        // we should never run into this issue
        #[allow(clippy::cast_possible_truncation)]
        let elapsed = now.elapsed().as_millis() as u64;

        Ok(Some(ProcessedBuild {
            _id: id,
            nr_added,
            new_runnable,
            elapsed,
        }))
    }

    #[tracing::instrument(skip(self, new_ids, new_builds_by_id, new_builds_by_path), err)]
    async fn process_new_builds(
        &self,
        new_ids: Vec<BuildID>,
        new_builds_by_id: Arc<parking_lot::RwLock<HashMap<BuildID, Arc<Build>>>>,
        new_builds_by_path: HashMap<StorePath, HashSet<BuildID>>,
    ) -> Result<bool, StateError> {
        use futures::stream::StreamExt as _;

        let finished_drvs = Arc::new(parking_lot::RwLock::new(HashSet::<StorePath>::new()));
        let new_builds_by_path = Arc::new(new_builds_by_path);
        let starttime = jiff::Timestamp::now();

        let mut futures = futures::stream::FuturesUnordered::new();
        let mut ids_iter = new_ids.into_iter();

        for _ in 0..MAX_CONCURRENT_BUILD_INJECTION {
            if let Some(id) = ids_iter.next() {
                futures.push(Box::pin(Self::process_single_build(
                    self,
                    id,
                    new_builds_by_id.clone(),
                    new_builds_by_path.clone(),
                    finished_drvs.clone(),
                )));
            }
        }

        let mut early_exit = false;

        while let Some(result) = futures.next().await {
            let processed = result?;

            // Check early exit only once, after each completed build.
            // If already exiting, we let in-flight tasks drain naturally.
            if !early_exit {
                let stop_queue_run_after = self.config.get_stop_queue_run_after();
                if let Some(stop_queue_run_after) = stop_queue_run_after
                    && jiff::Timestamp::now() > (starttime + stop_queue_run_after)
                {
                    early_exit = true;
                    self.metrics.queue_checks_early_exits.inc();
                }
            }

            // Refill for every completed future, also those that resolved to
            // None, otherwise the in-flight set shrinks until the run ends.
            if !early_exit && let Some(id) = ids_iter.next() {
                futures.push(Box::pin(Self::process_single_build(
                    self,
                    id,
                    new_builds_by_id.clone(),
                    new_builds_by_path.clone(),
                    finished_drvs.clone(),
                )));
            }

            let Some(ProcessedBuild {
                nr_added,
                new_runnable,
                elapsed,
                ..
            }) = processed
            else {
                continue;
            };

            self.metrics.build_read_time_ms.inc_by(elapsed);

            {
                let new_runnable = new_runnable.read();
                tracing::info!(
                    "got {} new runnable steps from {} new builds",
                    new_runnable.len(),
                    nr_added.load(Ordering::Relaxed)
                );
                for r in new_runnable.iter() {
                    r.make_runnable();
                }
            }
            if let Ok(added_u64) = u64::try_from(nr_added.load(Ordering::Relaxed)) {
                self.metrics.nr_builds_read.inc_by(added_u64);
            }
        }

        // This is here to ensure that we dont have any deps to finished steps
        // This can happen because step creation is async and is_new can return a step that is
        // still undecided if its finished or not.
        self.steps.make_rdeps_runnable();

        // we can just always trigger dispatch as we might have a free machine and its cheap
        self.metrics.queue_checks_finished.inc();
        self.trigger_dispatch();
        if let Some(fod_checker) = &self.fod_checker {
            fod_checker.trigger_traverse();
        }
        Ok(early_exit)
    }

    #[tracing::instrument(skip(self), err)]
    async fn process_queue_change(&self) -> Result<(), db::Error> {
        let mut db = self.db.get().await?;
        let curr_ids: HashMap<_, _> = db
            .get_not_finished_builds_fast()
            .await?
            .into_iter()
            .map(|b| (b.id, b.globalpriority))
            .collect();
        self.builds.update_priorities(&curr_ids);

        let cancelled_steps = self.queues.kill_active_steps().await;
        for (drv_path, machine_id) in cancelled_steps {
            if let Err(e) = self
                .fail_step(
                    machine_id,
                    &drv_path,
                    BuildResultState::Cancelled,
                    BuildTimings::default(),
                    None,
                )
                .await
            {
                tracing::error!(
                    "Failed to abort step machine_id={machine_id} drv={drv_path} e={e}",
                );
            }
        }
        Ok(())
    }
}

/// Errors from looking up derivations.
#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum DrvLookupError {
    #[error("drv not found")]
    DrvNotFound,

    #[error("derivation not found")]
    DerivationNotFound,
}

impl State {
    #[tracing::instrument(skip(self), fields(%drv_path))]
    pub async fn queue_one_build(
        &self,
        jobset_id: i32,
        drv_path: &StorePath,
    ) -> Result<(), StateError> {
        let mut db = self.db.get().await?;
        let drv = self.read_derivation(drv_path).await?;
        db.insert_debug_build(
            self.pool.store_dir(),
            jobset_id,
            drv_path,
            std::str::from_utf8(&drv.platform).map_err(StateError::InvalidPlatformUtf8)?,
        )
        .await?;

        let mut tx = db.begin_transaction().await?;
        tx.notify_builds_added().await?;
        tx.commit().await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub(crate) async fn manually_add_queue_build(
        &self,
        build_id: BuildID,
    ) -> Result<(), StateError> {
        let mut new_ids = Vec::<BuildID>::new();
        let mut new_builds_by_id = HashMap::<BuildID, Arc<Build>>::new();
        let mut new_builds_by_path = HashMap::<StorePath, HashSet<BuildID>>::new();

        {
            let mut conn = self.db.get().await?;
            for b in conn
                .get_not_finished_builds(self.pool.store_dir())
                .await?
                .into_iter()
                .filter(|b| b.id == build_id)
            {
                let jobset = self
                    .jobsets
                    .create(&mut conn, b.jobset_id, &b.project, &b.jobset)
                    .await?;
                let build = Build::new(b, jobset)?;
                new_ids.push(build.id);
                new_builds_by_id.insert(build.id, build.clone());
                new_builds_by_path
                    .entry(build.drv_path.clone())
                    .or_insert_with(HashSet::new)
                    .insert(build.id);
            }
        }
        tracing::debug!("new_ids: {new_ids:?}");
        tracing::debug!("new_builds_by_id: {new_builds_by_id:?}");
        tracing::debug!("new_builds_by_path: {new_builds_by_path:?}");

        if new_ids.is_empty() {
            return Ok(());
        }

        let new_builds_by_id = Arc::new(parking_lot::RwLock::new(new_builds_by_id));
        let _early_exit =
            Box::pin(self.process_new_builds(new_ids, new_builds_by_id, new_builds_by_path))
                .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_queued_builds(&self) -> Result<bool, StateError> {
        self.metrics.queue_checks_started.inc();

        let mut new_ids = Vec::<BuildID>::with_capacity(1000);
        let mut new_builds_by_id = HashMap::<BuildID, Arc<Build>>::with_capacity(1000);
        let mut new_builds_by_path = HashMap::<StorePath, HashSet<BuildID>>::with_capacity(1000);

        {
            let mut conn = self.db.get().await?;
            for b in conn.get_not_finished_builds(self.pool.store_dir()).await? {
                let jobset = self
                    .jobsets
                    .create(&mut conn, b.jobset_id, &b.project, &b.jobset)
                    .await?;
                let build = Build::new(b, jobset)?;
                new_ids.push(build.id);
                new_builds_by_id.insert(build.id, build.clone());
                new_builds_by_path
                    .entry(build.drv_path.clone())
                    .or_insert_with(HashSet::new)
                    .insert(build.id);
            }
        }
        tracing::debug!("new_ids: {new_ids:?}");
        tracing::debug!("new_builds_by_id: {new_builds_by_id:?}");
        tracing::debug!("new_builds_by_path: {new_builds_by_path:?}");

        let new_builds_by_id = Arc::new(parking_lot::RwLock::new(new_builds_by_id));
        let early_exit =
            Box::pin(self.process_new_builds(new_ids, new_builds_by_id, new_builds_by_path))
                .await?;
        Ok(early_exit)
    }

    #[tracing::instrument(skip(self))]
    pub fn start_queue_monitor_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                if let Err(e) = Box::pin(self.queue_monitor_loop()).await {
                    tracing::error!("Failed to spawn queue monitor loop. e={e}");
                }
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self), err)]
    async fn queue_monitor_loop(&self) -> Result<(), StateError> {
        let mut listener = self
            .db
            .listener(vec![
                "builds_added",
                "builds_restarted",
                "builds_cancelled",
                "builds_deleted",
                "builds_bumped",
                "jobset_shares_changed",
            ])
            .await?;

        loop {
            let before_work = Instant::now();
            // no cache in daemon protocol
            let early_exit = match self.get_queued_builds().await {
                Ok(early_exit) => early_exit,
                Err(e) => {
                    tracing::error!("get_queue_builds failed inside queue monitor loop: {e}");
                    continue;
                }
            };

            #[allow(clippy::cast_possible_truncation)]
            self.metrics
                .queue_monitor_time_spent_running
                .inc_by(before_work.elapsed().as_micros() as u64);

            let before_sleep = Instant::now();
            let queue_trigger_timer = self.config.get_queue_trigger_timer();
            let notification = if early_exit {
                // Short poll: process maybe pending notifications, then re-run immediately.
                let short_poll = std::time::Duration::from_millis(100);
                tokio::select! {
                    () = tokio::time::sleep(short_poll) => {"timer_reached".into()},
                    v = listener.try_next() => match v {
                        Ok(Some(v)) => v.channel().to_owned(),
                        Ok(None) => continue,
                        Err(e) => {
                            tracing::warn!("PgListener failed with e={e}");
                            continue;
                        }
                    },
                }
            } else if let Some(timer) = queue_trigger_timer {
                tokio::select! {
                    () = tokio::time::sleep(timer) => {"timer_reached".into()},
                    v = listener.try_next() => match v {
                        Ok(Some(v)) => v.channel().to_owned(),
                        Ok(None) => continue,
                        Err(e) => {
                            tracing::warn!("PgListener failed with e={e}");
                            continue;
                        }
                    },
                }
            } else {
                match listener.try_next().await {
                    Ok(Some(v)) => v.channel().to_owned(),
                    Ok(None) => continue,
                    Err(e) => {
                        tracing::warn!("PgListener failed with e={e}");
                        continue;
                    }
                }
            };
            self.metrics.nr_queue_wakeups.inc();
            tracing::trace!("New notification from PgListener. notification={notification:?}");

            match notification.as_ref() {
                "builds_added" => {
                    tracing::debug!("got notification: new builds added to the queue");
                }
                "builds_restarted" => tracing::debug!("got notification: builds restarted"),
                "builds_cancelled" | "builds_deleted" | "builds_bumped" => {
                    tracing::info!("got notification: builds cancelled or bumped");
                    if let Err(e) = self.process_queue_change().await {
                        tracing::error!("Failed to process queue change. e={e}");
                    }
                }
                "jobset_shares_changed" => {
                    tracing::info!("got notification: jobset shares changed");
                    match self.db.get().await {
                        Ok(mut conn) => {
                            if let Err(e) = self.jobsets.handle_change(&mut conn).await {
                                tracing::error!("Failed to handle jobset change. e={e}");
                            }
                        }
                        Err(e) => {
                            tracing::error!(
                                "Failed to get db connection for event 'jobset_shares_changed'. e={e}"
                            );
                        }
                    }
                }
                _ => (),
            }

            #[allow(clippy::cast_possible_truncation)]
            self.metrics
                .queue_monitor_time_spent_waiting
                .inc_by(before_sleep.elapsed().as_micros() as u64);
        }
    }

    #[tracing::instrument(skip(self))]
    pub fn start_dispatch_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                loop {
                    let before_sleep = Instant::now();
                    let dispatch_trigger_timer = self.config.get_dispatch_trigger_timer();
                    if let Some(timer) = dispatch_trigger_timer {
                        tokio::select! {
                            () = self.notify_dispatch.notified() => {},
                            () = tokio::time::sleep(timer) => {},
                        };
                    } else {
                        self.notify_dispatch.notified().await;
                    }
                    tracing::info!("starting dispatch");

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatcher_time_spent_waiting
                        .inc_by(before_sleep.elapsed().as_micros() as u64);

                    self.metrics.nr_dispatcher_wakeups.inc();
                    let before_work = Instant::now();
                    self.clone().do_dispatch_once().await;

                    let elapsed = before_work.elapsed();
                    // Coalesce trigger bursts; every finished build notifies.
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatcher_time_spent_running
                        .inc_by(elapsed.as_micros() as u64);

                    #[allow(clippy::cast_possible_truncation)]
                    self.metrics
                        .dispatch_time_ms
                        .inc_by(elapsed.as_millis() as u64);
                }
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self))]
    pub fn start_uploader_queue(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn({
            async move {
                loop {
                    let local_db = self.local_db.clone();
                    let local_store = self.pool.clone();
                    let s3_stores: Vec<binary_cache::S3BinaryCacheClient> = {
                        let r = self.remote_stores.read();
                        r.iter()
                            .filter_map(|s| match s {
                                RemoteStoreBackend::S3(s) => Some(s.clone()),
                                RemoteStoreBackend::NixCopy(_) => None,
                            })
                            .collect()
                    };
                    let limit = self.config.get_concurrent_upload_limit();
                    if limit < 2 {
                        self.uploader
                            .upload_once(local_db, local_store, s3_stores)
                            .await;
                    } else {
                        self.uploader
                            .upload_many(local_db, local_store, s3_stores, limit)
                            .await;
                    }
                }
            }
        });
        task.abort_handle()
    }

    /// Process upload completions for steps gated on
    /// [`OutputAvailability::PendingUpload`]: only once their outputs exist
    /// in the remote binary cache that builders fetch inputs from may the
    /// steps finish and their rdeps be dispatched.
    #[tracing::instrument(skip(self))]
    pub fn start_upload_completion_loop(self: Arc<Self>) -> tokio::task::AbortHandle {
        let task = tokio::task::spawn(async move {
            let Some(mut rx) = self.upload_completion_rx.lock().take() else {
                tracing::error!("upload completion loop started twice");
                return;
            };
            while let Some(drv_path) = rx.recv().await {
                self.finish_uploaded_step(&drv_path).await;
            }
        });
        task.abort_handle()
    }

    #[tracing::instrument(skip(self), fields(%drv_path))]
    async fn finish_uploaded_step(&self, drv_path: &StorePath) {
        let Some(step) = self.steps.get(drv_path) else {
            // Step is gone (e.g. the upload was re-queued from disk after a
            // restart); the queue monitor revalidates it on the next run.
            return;
        };
        if step.get_finished() {
            return;
        }
        complete_step(&step);
        if let Some(fod_checker) = &self.fod_checker {
            fod_checker.to_traverse(drv_path);
        }
        // Builds with this step as toplevel are now cached successes.
        for build in step.get_direct_builds() {
            let build_id = build.id;
            if let Err(e) = self.handle_cached_build(build).await {
                tracing::error!("failed to handle cached build: {e}");
            }
            self.builds.remove_by_id(build_id);
        }
        self.trigger_dispatch();
    }

    #[tracing::instrument(skip(self))]
    pub fn trigger_dispatch(&self) {
        self.notify_dispatch.notify_one();
    }

    #[tracing::instrument(skip(self))]
    async fn do_dispatch_once(self: Arc<Self>) {
        // Prune old historical build step info from the jobsets.
        self.jobsets.prune();
        if self.config.get_step_sort_fn() == crate::config::StepSortFn::WithCriticalPath {
            // New steps start with cp_length 0 and sort last until the next
            // recomputation; acceptable for a priority heuristic.
            self.steps.compute_critical_paths_throttled(60);
        }
        let mut new_runnable = self.steps.drain_pending_runnable();
        new_runnable.extend(self.steps.clone_runnable_throttled(300));

        let now = jiff::Timestamp::now();
        let mut new_queues = HashMap::<System, Vec<StepInfo>>::with_capacity(10);
        for r in new_runnable {
            let Some(system) = r.get_system() else {
                continue;
            };
            if r.atomic_state.tries.load(Ordering::Relaxed) > 0 {
                continue;
            }
            // Only offer steps that are not already held in the queues.
            if !r.try_mark_queued() {
                continue;
            }
            let step_info = StepInfo::new(r.clone());

            new_queues
                .entry(system)
                .or_insert_with(|| Vec::with_capacity(100))
                .push(step_info);
        }

        for (system, jobs) in new_queues {
            self.queues
                .insert_new_jobs(
                    system,
                    jobs,
                    &now,
                    self.config.get_step_sort_fn(),
                    &self.metrics,
                )
                .await;
        }
        self.queues.remove_all_weak_pointer().await;

        let free_fn = self.config.get_machine_free_fn();
        let nr_steps_waiting_all_queues = self
            .queues
            .process(
                {
                    let state = self.clone();
                    async move |constraint: queue::JobConstraint| {
                        Box::pin(state.clone().realise_drv_on_valid_machine(constraint)).await
                    }
                },
                |system: &str| self.machines.has_capacity_for_system(system, free_fn),
                &self.metrics,
            )
            .await;
        self.metrics
            .nr_steps_waiting
            .set(nr_steps_waiting_all_queues);

        self.abort_unsupported().await;
    }

    #[tracing::instrument(skip(self, step_status), fields(%build_id, %machine_id), err)]
    pub async fn update_build_step(
        &self,
        build_id: uuid::Uuid,
        machine_id: uuid::Uuid,
        step_status: db::models::StepStatus,
    ) -> Result<(), db::Error> {
        let build_id_and_step_nr = self.machines.get_machine_by_id(machine_id).and_then(|m| {
            tracing::debug!(
                "get job from machine by build_id: build_id={build_id} m={}",
                m.id
            );
            m.get_build_id_and_step_nr_by_uuid(build_id)
        });

        let Some((build_id, step_nr)) = build_id_and_step_nr else {
            tracing::warn!(
                "Failed to find job with build_id and step_nr for build_id={build_id:?} machine_id={machine_id:?}."
            );
            return Ok(());
        };
        self.db
            .get()
            .await?
            .update_build_step(db::models::UpdateBuildStep {
                build_id,
                step_nr,
                status: step_status,
            })
            .await?;
        Ok(())
    }
}

/// Errors from looking up steps/jobs in the in-memory queues.
#[derive(Debug, thiserror::Error)]
pub enum StepLookupError {
    #[error("step is missing in queues.scheduled")]
    StepNotScheduled,

    #[error("job is missing in machine.jobs m={0}")]
    JobNotOnMachine(String),
}

impl State {
    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(self, output), fields(%machine_id, %drv_path), err)]
    pub async fn succeed_step(
        &self,
        machine_id: uuid::Uuid,
        drv_path: &StorePath,
        output: BuildOutput,
    ) -> Result<(), StateError> {
        tracing::info!("marking job as done: drv_path={drv_path}");
        let item = self
            .queues
            .remove_job_from_scheduled(drv_path)
            .await
            .ok_or(StateError::from(StepLookupError::StepNotScheduled))?;

        item.step_info.step.set_finished(true);

        // Verify that for outputs with statically-known paths (input-addressed
        // and fixed content-addressed), the paths reported by the builder match
        // what we compute from the derivation.  A mismatch here would mean that
        // the queue runner and builder are disagreeing on what the drv itself
        // means (regardless of what it produces) which would be an "all bets
        // are off" bug.
        if let Some(expected) = item.step_info.step.get_output_paths() {
            for (name, expected_path) in &expected {
                let Some(expected_path) = expected_path else {
                    continue; // path not statically known (Deferred/CAFloating/Impure)
                };
                if let Some(actual_path) = output.outputs.get(name)
                    && expected_path != actual_path
                {
                    return Err(StateError::from(ResolutionError::OutputPathMismatch {
                        name: name.to_string(),
                        drv: drv_path.clone(),
                        expected: self.pool.store_dir().display(expected_path).to_string(),
                        actual: self.pool.store_dir().display(actual_path).to_string(),
                    }));
                }
            }
        }

        tracing::debug!(
            "removing job from machine: drv_path={drv_path} m={}",
            item.machine.id
        );
        let mut job = item.machine.remove_job(drv_path).ok_or_else(|| {
            StateError::from(StepLookupError::JobNotOnMachine(item.machine.to_string()))
        })?;
        self.queues
            .remove_job(&item.step_info, &item.build_queue)
            .await;

        job.result.step_status = BuildStatus::Success;
        job.result.set_stop_time_now();
        job.result.set_overhead(output.timings.get_overhead())?;

        let total_step_time = job.result.get_total_step_time_ms();
        item.machine
            .stats
            .track_build_success(output.timings, total_step_time);
        self.metrics
            .track_build_success(output.timings, total_step_time);

        finish_build_step(
            &self.db,
            self.pool.store_dir(),
            job.build_id,
            job.step_nr,
            &job.result,
            Some(&item.machine.hostname),
            Some(&output.outputs),
        )
        .await?;

        // Copy outputs to non-S3 stores via `nix copy`.
        {
            let nix_copy_uris: Vec<String> = {
                let stores = self.remote_stores.read();
                stores
                    .iter()
                    .filter_map(|s| match s {
                        RemoteStoreBackend::NixCopy(uri) => Some(uri.clone()),
                        RemoteStoreBackend::S3(_) => None,
                    })
                    .collect()
            };
            if !nix_copy_uris.is_empty() {
                let paths: Vec<String> = output
                    .outputs
                    .values()
                    .map(|p| self.pool.store_dir().display(p).to_string())
                    .collect();
                for dest_uri in &nix_copy_uris {
                    let output = tokio::process::Command::new("nix")
                        .arg("--extra-experimental-features")
                        .arg("nix-command")
                        .arg("copy")
                        .arg("--from")
                        .arg(self.nix_daemon_config.to_uri())
                        .arg("--to")
                        .arg(dest_uri)
                        .args(&paths)
                        .output()
                        .await;
                    match output {
                        Ok(out) if out.status.success() => {
                            tracing::info!("Copied {} paths to {dest_uri}", paths.len());
                        }
                        Ok(out) => {
                            tracing::error!(
                                "nix copy to {dest_uri} failed: {}",
                                str::from_utf8(&out.stderr).unwrap_or("Invalid UTF-8")
                            );
                        }
                        Err(e) => {
                            tracing::error!("Failed to run nix copy to {dest_uri}: {e}");
                        }
                    }
                }
            }
        }

        let has_s3_stores = {
            let r = self.remote_stores.read();
            r.iter().any(|s| matches!(s, RemoteStoreBackend::S3(_)))
        };
        if has_s3_stores {
            // Only upload outputs if presigned uploads are NOT enabled
            // When presigned uploads are enabled, builder handles NAR uploads directly
            if !self.config.use_presigned_uploads() {
                let outputs_to_upload = output
                    .outputs
                    .values()
                    .map(Clone::clone)
                    .collect::<Vec<_>>();

                self.uploader
                    .schedule_upload(
                        outputs_to_upload,
                        format!("log/{}", job.path),
                        job.result.log_file.clone(),
                        None,
                    )
                    .await;
            }
        }

        // Write realisations for CA floating outputs to binary caches.
        // This maps (resolved_drv_path, output_name) -> concrete_output_path,
        // allowing clients to look up outputs by derivation path.
        //
        // TODO: also write realisations to the local store's SQLite
        // `Realisations` table (for non-S3 / FFI stores) once nix is
        // updated to 2.35, which uses path-based DrvOutput matching
        // the harmonia types.
        {
            let has_ca_floating = item.step_info.step.has_ca_floating_outputs();
            if has_ca_floating {
                let s3_stores: Vec<binary_cache::S3BinaryCacheClient> = {
                    let r = self.remote_stores.read();
                    r.iter()
                        .filter_map(|s| match s {
                            RemoteStoreBackend::S3(s) => Some(s.clone()),
                            RemoteStoreBackend::NixCopy(_) => None,
                        })
                        .collect()
                };
                for (output_name, out_path) in &output.outputs {
                    let realisation = Realisation {
                        key: DrvOutput {
                            drv_path: drv_path.clone(),
                            output_name: output_name.clone(),
                        },
                        value: UnkeyedRealisation {
                            out_path: out_path.clone(),
                            signatures: BTreeSet::default(),
                        },
                    };
                    for s3 in &s3_stores {
                        if let Err(e) = s3.write_realisation(realisation.clone()).await {
                            tracing::warn!(
                                "Failed to write realisation for {drv_path}^{output_name}: {e}"
                            );
                        }
                    }
                }
            }
        }

        let direct = item.step_info.step.get_direct_builds();
        if direct.is_empty() {
            self.steps.remove(item.step_info.step.get_drv_path());
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            let start_time = job.result.get_start_time_as_i32()?;
            let stop_time = job.result.get_stop_time_as_i32()?;
            for b in &direct {
                let is_cached = job.build_id != b.id || job.result.is_cached;
                tx.mark_succeeded_build(
                    get_mark_build_sccuess_data(b, &output),
                    is_cached,
                    start_time,
                    stop_time,
                    self.pool.store_dir(),
                )
                .await?;
                self.metrics.nr_builds_done.inc();
            }

            tx.commit().await?;
        }

        // Remove the direct dependencies from 'builds'. This will cause them to be
        // destroyed.
        for b in &direct {
            b.set_finished_in_db(true);
            self.builds.remove_by_id(b.id);
        }

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            for b in &direct {
                tx.notify_build_finished(b.id, &[]).await?;
            }

            tx.commit().await?;
        }

        // Process dynamic rdeps first, as we must add new step dependencies for dynamically
        // generated derivations
        {
            for (dep_step, output_name, relation) in item.step_info.step.pop_dynamic_rdeps() {
                let Some(dependent_step) = dep_step.upgrade() else {
                    continue;
                };

                let resolved_drv = output.outputs.get(&output_name).cloned().ok_or_else(|| {
                    StateError::from(ResolutionError::DynRdepOutputMissing {
                        output: output_name.to_string(),
                        drv: drv_path.clone(),
                    })
                })?;

                // Find a build associated with this step. For intermediate steps
                // (not top-level), `direct` is empty, so we walk the dependency
                // chain via `get_dependents` to find the owning build.
                let build = if let Some(b) = direct.first() {
                    b.clone()
                } else {
                    let mut dependents = HashSet::new();
                    let mut visited_steps = HashSet::new();
                    item.step_info
                        .step
                        .get_dependents(&mut dependents, &mut visited_steps);
                    let Some(b) = dependents.into_iter().next() else {
                        tracing::warn!("Finished step does not have associated build");
                        continue;
                    };
                    b
                };

                // Create the actual step for the new derivation.
                // finished_drvs is not necessary as it is only a memoization table to reduce
                // checks if a dependency is finished from the database.
                // new_steps is not necessary either as
                let new_runnable: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>> = Arc::default();
                let new_step = match self
                    .create_step(
                        build.clone(),
                        resolved_drv.clone(),
                        None,
                        Some((dependent_step.clone(), relation)),
                        Arc::default(),
                        Arc::default(),
                        new_runnable.clone(),
                    )
                    .await
                {
                    CreateStepResult::None => continue,
                    CreateStepResult::Valid(step) => step,
                    CreateStepResult::PreviousFailure(step) => {
                        if let Err(e) = self.handle_previous_failure(build.clone(), step).await {
                            tracing::error!("Failed to handle previous failure: {e}");
                        }
                        // TODO: figure out what to do here
                        continue;
                    }
                };

                for r in new_runnable.read().iter() {
                    r.make_runnable();
                }

                // create_step already added the rdep; add the forward dep
                // unless the new step finished in the meantime (then its
                // make_rdeps_runnable already woke the dependent and the dep
                // would linger in deps forever).
                dependent_step.add_dep_if_unfinished(new_step);
            }
        }
        item.step_info.step.make_rdeps_runnable();

        // always trigger dispatch, as we now might have a free machine again
        self.trigger_dispatch();

        Ok(())
    }

    #[tracing::instrument(skip(self), fields(%machine_id, %drv_path), err)]
    pub async fn fail_step(
        &self,
        machine_id: uuid::Uuid,
        drv_path: &StorePath,
        state: BuildResultState,
        timings: BuildTimings,
        error_msg: Option<String>,
    ) -> Result<(), StateError> {
        tracing::info!("removing job from running in system queue: drv_path={drv_path}");
        let item = self
            .queues
            .remove_job_from_scheduled(drv_path)
            .await
            .ok_or(StateError::from(StepLookupError::StepNotScheduled))?;

        item.step_info.step.set_finished(false);

        tracing::debug!(
            "removing job from machine: drv_path={drv_path} m={}",
            item.machine.id
        );
        let mut job = item.machine.remove_job(drv_path).ok_or_else(|| {
            StateError::from(StepLookupError::JobNotOnMachine(item.machine.to_string()))
        })?;

        job.result.step_status = BuildStatus::Failed;
        // this can override step_status to something more specific
        job.result.update_with_result_state(state);
        if let Some(error_msg) = error_msg {
            job.result.error_msg = Some(error_msg);
        }
        job.result.set_stop_time_now();
        job.result.set_overhead(timings.get_overhead())?;

        let total_step_time = job.result.get_total_step_time_ms();
        item.machine
            .stats
            .track_build_failure(timings, total_step_time);
        self.metrics.track_build_failure(timings, total_step_time);

        let (max_retries, retry_interval, retry_backoff) = self.config.get_retry();

        if job.result.can_retry {
            item.step_info
                .step
                .atomic_state
                .tries
                .fetch_add(1, Ordering::Relaxed);
            let tries = item
                .step_info
                .step
                .atomic_state
                .tries
                .load(Ordering::Relaxed);
            if tries < max_retries {
                self.metrics.nr_retries.inc();
                #[allow(clippy::cast_possible_truncation, clippy::cast_precision_loss)]
                let delta = (retry_interval * retry_backoff.powf((tries - 1) as f32)) as i64;
                tracing::info!("will retry '{drv_path}' after {delta}s");
                item.step_info
                    .step
                    .set_after(jiff::Timestamp::now() + jiff::SignedDuration::from_secs(delta));
                if i64::from(tries) > self.metrics.max_nr_retries.get() {
                    self.metrics.max_nr_retries.set(i64::from(tries));
                }

                item.step_info.set_already_scheduled(false);

                finish_build_step(
                    &self.db,
                    self.pool.store_dir(),
                    job.build_id,
                    job.step_nr,
                    &job.result,
                    Some(&item.machine.hostname),
                    None,
                )
                .await?;
                self.trigger_dispatch();
                return Ok(());
            }
        }

        // remove job from queues, aka actually fail the job
        self.queues
            .remove_job(&item.step_info, &item.build_queue)
            .await;

        self.inner_fail_job(
            drv_path,
            Some(item.machine),
            job,
            item.step_info.step.clone(),
        )
        .await
    }
}

/// Errors from looking up machines/jobs by UUID.
#[derive(Debug, Clone, Copy, thiserror::Error)]
pub enum MachineLookupError {
    #[error("machine with machine_id not found")]
    MachineNotFound,

    #[error("job with build_id not found")]
    JobNotFound,
}

impl State {
    #[tracing::instrument(skip(self, output), fields(%machine_id, build_id=%build_id), err)]
    pub async fn succeed_step_by_uuid(
        &self,
        build_id: uuid::Uuid,
        machine_id: uuid::Uuid,
        output: BuildOutput,
    ) -> Result<(), StateError> {
        let machine = self
            .machines
            .get_machine_by_id(machine_id)
            .ok_or(StateError::from(MachineLookupError::MachineNotFound))?;
        let drv_path = machine
            .get_job_drv_for_build_id(build_id)
            .ok_or(StateError::from(MachineLookupError::JobNotFound))?;

        self.succeed_step(machine_id, &drv_path, output).await
    }

    #[tracing::instrument(skip(self), fields(%machine_id, build_id=%build_id), err)]
    pub async fn fail_step_by_uuid(
        &self,
        build_id: uuid::Uuid,
        machine_id: uuid::Uuid,
        state: BuildResultState,
        timings: BuildTimings,
        error_msg: Option<String>,
    ) -> Result<(), StateError> {
        let machine = self
            .machines
            .get_machine_by_id(machine_id)
            .ok_or(StateError::from(MachineLookupError::MachineNotFound))?;
        let drv_path = machine
            .get_job_drv_for_build_id(build_id)
            .ok_or(StateError::from(MachineLookupError::JobNotFound))?;

        self.fail_step(machine_id, &drv_path, state, timings, error_msg)
            .await
    }

    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(self, machine, job, step), fields(%drv_path), err)]
    async fn inner_fail_job(
        &self,
        drv_path: &StorePath,
        machine: Option<Arc<Machine>>,
        mut job: machine::Job,
        step: Arc<Step>,
    ) -> Result<(), StateError> {
        if !job.result.has_stop_time() {
            job.result.set_stop_time_now();
        }

        if job.step_nr != 0 {
            finish_build_step(
                &self.db,
                self.pool.store_dir(),
                job.build_id,
                job.step_nr,
                &job.result,
                machine.as_ref().map(|m| m.hostname.as_str()),
                None,
            )
            .await?;
        }

        let mut dependent_ids = Vec::new();
        let mut step_finished = false;
        loop {
            let indirect = self.get_all_indirect_builds(&step);
            if indirect.is_empty() && step_finished {
                break;
            }

            // Create failed build steps for every build that depends on this, except when this
            // step is cached and is the top-level of that build (since then it's redundant with
            // the build's isCachedBuild field).
            {
                let mut db = self.db.get().await?;
                let mut tx = db.begin_transaction().await?;
                for b in &indirect {
                    if (job.result.step_status == BuildStatus::CachedFailure
                        && &b.drv_path == step.get_drv_path())
                        || ((job.result.step_status != BuildStatus::CachedFailure
                            && job.result.step_status != BuildStatus::Unsupported)
                            && job.build_id == b.id)
                        || b.get_finished_in_db()
                    {
                        continue;
                    }

                    tx.create_build_step(
                        self.pool.store_dir(),
                        None,
                        b.id,
                        step.get_drv_path(),
                        step.get_system().as_deref(),
                        machine
                            .as_deref()
                            .map(|m| m.hostname.clone())
                            .unwrap_or_default(),
                        job.result.step_status,
                        job.result.error_msg.clone(),
                        if job.build_id == b.id {
                            None
                        } else {
                            Some(job.build_id)
                        },
                        step.get_output_paths()
                            .unwrap_or_default()
                            .into_iter()
                            .collect(),
                    )
                    .await?;
                }

                // Mark all builds that depend on this derivation as failed.
                for b in &indirect {
                    if b.get_finished_in_db() {
                        continue;
                    }

                    tracing::info!("marking build {} as failed", b.id);
                    let start_time = job.result.get_start_time_as_i32()?;
                    let stop_time = job.result.get_stop_time_as_i32()?;
                    tx.update_build_after_failure(
                        b.id,
                        if &b.drv_path != step.get_drv_path()
                            && job.result.step_status == BuildStatus::Failed
                        {
                            BuildStatus::DepFailed
                        } else {
                            job.result.step_status
                        },
                        start_time,
                        stop_time,
                        job.result.step_status == BuildStatus::CachedFailure,
                    )
                    .await?;
                    self.metrics.nr_builds_done.inc();
                }

                // Remember failed paths in the database so that they won't be built again.
                if job.result.step_status != BuildStatus::CachedFailure && job.result.can_cache {
                    for (_, path) in step.get_output_paths().unwrap_or_default() {
                        if let Some(path) = path {
                            tx.insert_failed_paths(self.pool.store_dir(), &path).await?;
                        }
                    }
                }

                tx.commit().await?;
            }

            step_finished = true;

            // Remove the indirect dependencies from 'builds'. This will cause them to be
            // destroyed.
            for b in indirect {
                b.set_finished_in_db(true);
                self.builds.remove_by_id(b.id);
                dependent_ids.push(b.id);
            }
        }
        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;
            tx.notify_build_finished(job.build_id, &dependent_ids)
                .await?;
            tx.commit().await?;
        }

        // trigger dispatch, as we now have a free mashine again
        self.trigger_dispatch();

        Ok(())
    }

    #[tracing::instrument(skip(self, step))]
    fn get_all_indirect_builds(&self, step: &Arc<Step>) -> HashSet<Arc<Build>> {
        let mut indirect = HashSet::new();
        let mut steps = HashSet::new();
        step.get_dependents(&mut indirect, &mut steps);

        // If there are no builds left, delete all referring
        // steps from ‘steps’. As for the success case, we can
        // be certain no new referrers can be added.
        if indirect.is_empty() {
            for s in steps {
                let drv = s.get_drv_path();
                tracing::debug!("finishing build step '{drv}'");
                self.steps.remove(drv);
            }
        }

        indirect
    }

    #[tracing::instrument(skip(self, build, step), err)]
    async fn handle_previous_failure(
        &self,
        build: Arc<Build>,
        step: Arc<Step>,
    ) -> Result<(), StateError> {
        // Some step previously failed, so mark the build as failed right away.
        tracing::warn!(
            "marking build {} as cached failure due to '{}'",
            build.id,
            step.get_drv_path()
        );
        if build.get_finished_in_db() {
            return Ok(());
        }

        // if !build.finished_in_db
        let mut conn = self.db.get().await?;
        let mut tx = conn.begin_transaction().await?;

        // Find the previous build step record, first by derivation path, then by output
        // path.
        let mut propagated_from = tx
            .get_last_build_step_id(self.pool.store_dir(), step.get_drv_path())
            .await?
            .unwrap_or_default();

        if propagated_from == 0 {
            // we can access step.drv here because the value is always set if
            // PreviousFailure is returned, so this should never yield None

            let outputs = step.get_output_paths().unwrap_or_default();
            for (name, path) in &outputs {
                let res = if let Some(path) = path {
                    tx.get_last_build_step_id_for_output_path(self.pool.store_dir(), path)
                        .await
                } else {
                    tx.get_last_build_step_id_for_output_with_drv(
                        self.pool.store_dir(),
                        step.get_drv_path(),
                        name.as_ref(),
                    )
                    .await
                };
                if let Ok(Some(res)) = res {
                    propagated_from = res;
                    break;
                }
            }
        }

        tx.create_build_step(
            self.pool.store_dir(),
            None,
            build.id,
            step.get_drv_path(),
            step.get_system().as_deref(),
            String::new(),
            BuildStatus::CachedFailure,
            None,
            Some(propagated_from),
            step.get_output_paths()
                .unwrap_or_default()
                .into_iter()
                .collect(),
        )
        .await?;
        tx.update_build_after_previous_failure(
            build.id,
            if step.get_drv_path() == &build.drv_path {
                BuildStatus::Failed
            } else {
                BuildStatus::DepFailed
            },
        )
        .await?;

        let _ = tx.notify_build_finished(build.id, &[]).await;
        tx.commit().await?;

        build.set_finished_in_db(true);
        self.metrics.nr_builds_done.inc();
        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(
        self,
        build,
        nr_added,
        new_builds_by_id,
        new_builds_by_path,
        finished_drvs,
        new_runnable
    ), fields(build_id=build.id))]
    async fn create_build(
        &self,
        build: Arc<Build>,
        nr_added: Arc<AtomicI64>,
        new_builds_by_id: Arc<parking_lot::RwLock<HashMap<BuildID, Arc<Build>>>>,
        new_builds_by_path: Arc<HashMap<StorePath, HashSet<BuildID>>>,
        finished_drvs: Arc<parking_lot::RwLock<HashSet<StorePath>>>,
        new_runnable: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>>,
    ) -> Result<(), StateError> {
        self.metrics.queue_build_loads.inc();
        tracing::info!("loading build {} ({})", build.id, build.full_job_name());
        nr_added.fetch_add(1, Ordering::Relaxed);
        {
            let mut new_builds_by_id = new_builds_by_id.write();
            new_builds_by_id.remove(&build.id);
        }

        if !self.is_valid_path(&build.drv_path).await? {
            tracing::error!(
                "aborting GC'ed build id={} path={}",
                build.id,
                self.pool.store_dir().display(&build.drv_path)
            );
            if !build.get_finished_in_db() {
                match self.db.get().await {
                    Ok(mut conn) => {
                        if let Err(e) = conn.abort_build(build.id).await {
                            tracing::error!("Failed to abort the build={} e={}", build.id, e);
                        }
                    }
                    Err(e) => tracing::error!(
                        "Failed to get database connection so we can abort the build={} e={}",
                        build.id,
                        e
                    ),
                }
            }

            build.set_finished_in_db(true);
            self.metrics.nr_builds_done.inc();
            return Ok(());
        }

        // Create steps for this derivation and its dependencies.
        let new_steps = Arc::new(parking_lot::RwLock::new(HashSet::<Arc<Step>>::new()));
        let step = match self
            .create_step(
                // conn,
                build.clone(),
                build.drv_path.clone(),
                Some(build.clone()),
                None,
                finished_drvs.clone(),
                new_steps.clone(),
                new_runnable.clone(),
            )
            .await
        {
            CreateStepResult::None => None,
            CreateStepResult::Valid(dep) => Some(dep),
            CreateStepResult::PreviousFailure(step) => {
                if let Err(e) = self.handle_previous_failure(build, step).await {
                    tracing::error!("Failed to handle previous failure: {e}");
                }
                return Ok(());
            }
        };

        {
            use futures::stream::StreamExt as _;

            let builds = {
                let new_steps = new_steps.read();
                new_steps
                    .iter()
                    .filter_map(|r| Some(new_builds_by_path.get(r.get_drv_path())?.clone()))
                    .flatten()
                    .collect::<Vec<_>>()
            };
            let mut stream = futures::StreamExt::map(tokio_stream::iter(builds), |b| {
                let nr_added = nr_added.clone();
                let new_builds_by_id = new_builds_by_id.clone();
                let new_builds_by_path = new_builds_by_path.clone();
                let finished_drvs = finished_drvs.clone();
                let new_runnable = new_runnable.clone();
                async move {
                    let j = {
                        if let Some(j) = new_builds_by_id.read().get(&b) {
                            j.clone()
                        } else {
                            return Ok(());
                        }
                    };

                    Box::pin(self.create_build(
                        j,
                        nr_added,
                        new_builds_by_id,
                        new_builds_by_path,
                        finished_drvs,
                        new_runnable,
                    ))
                    .await
                }
            })
            .buffered(10);
            while let Some(result) = tokio_stream::StreamExt::next(&mut stream).await {
                result?;
            }
        }

        if let Some(step) = step {
            if !build.get_finished_in_db() {
                self.builds.insert_new_build(build.clone());
            }

            build.set_toplevel_step(step.clone());
            build.propagate_priorities();

            tracing::info!(
                "added build {} (top-level step {}, {} new steps)",
                build.id,
                step.get_drv_path(),
                new_steps.read().len()
            );
        } else {
            // If we didn't get a step, it means the step's outputs are
            // all valid. So we mark this as a finished, cached build.
            if let Err(e) = self.handle_cached_build(build).await {
                tracing::error!("failed to handle cached build: {e}");
            }
        }
        Ok(())
    }

    #[allow(clippy::too_many_lines, clippy::too_many_arguments)]
    #[tracing::instrument(skip(
        self,
        build,
        referring_build,
        referring_step,
        finished_drvs,
        new_steps,
        new_runnable
    ), fields(build_id=build.id, %drv_path))]
    async fn create_step(
        &self,
        build: Arc<Build>,
        drv_path: StorePath,
        referring_build: Option<Arc<Build>>,
        referring_step: Option<(Arc<Step>, drv::OutputNameChain)>,
        finished_drvs: Arc<parking_lot::RwLock<HashSet<StorePath>>>,
        new_steps: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>>,
        new_runnable: Arc<parking_lot::RwLock<HashSet<Arc<Step>>>>,
    ) -> CreateStepResult {
        use futures::stream::StreamExt as _;

        {
            let finished_drvs = finished_drvs.read();
            if finished_drvs.contains(&drv_path) {
                return CreateStepResult::None;
            }
        }

        let (step, is_new) = self.steps.create(
            &drv_path,
            referring_build.as_ref(),
            referring_step
                .as_ref()
                .map(|(step, relation)| (step, relation.clone())),
        );
        if !is_new {
            // Re-check whether the step's outputs have appeared in the store
            // since it was first created. This handles the case where outputs
            // became available between poll cycles (e.g. built by a concurrent
            // step, substituted, or uploaded externally). Without this check,
            // builds whose outputs are now cached get stuck in an infinite
            // re-load loop: the DB says finished=0, the step already exists in
            // memory, and create_build never reaches handle_cached_build.
            //
            // To be clear, builds that go through gRPC do not need this. The
            // builder will push the info to the queue runner so there is no
            // polling race condition. It is likely that this case happened
            // because IFD in the evaluator was causing builds on the host, and
            // *those* were subject to the race condition --- build-relevant
            // store objects shouldn't be unexpected appearing in the host store
            // otherwise.
            //
            // TODO once we properly feed IFD builds in to Hydra to be
            // distributed, remove this hack.
            if step.get_finished() {
                return CreateStepResult::None;
            }
            if let Some(output_paths) = step.get_output_paths() {
                // All output paths must be known (Some) and valid in
                // the store for the step to count as finished.  CA
                // floating outputs have None paths until built.
                let all_resolved = output_paths.values().all(Option::is_some);
                let all_valid = if all_resolved {
                    let mut valid = true;
                    for path in output_paths.values().flatten() {
                        if !self.is_valid_path(path).await.unwrap_or(false) {
                            valid = false;
                            break;
                        }
                    }
                    valid
                } else {
                    false
                };
                if all_valid {
                    return self
                        .revalidate_locally_valid_step(step, &drv_path, &finished_drvs)
                        .await;
                }
            }
            return CreateStepResult::Valid(step);
        }
        self.metrics.queue_steps_created.inc();
        tracing::debug!("considering derivation '{drv_path}'");

        let Some(facts) = self.prefetch_step_facts(&build, &drv_path).await else {
            return CreateStepResult::None;
        };
        let StepFacts {
            drv,
            availability,
            previous_failure,
        } = facts;
        let input_drvs = drv::input_drvs(&drv);
        step.set_drv(&drv, self.pool.store_dir());

        // Recurse into the input derivations only when the step actually has
        // to be built; finished and previously-failed steps never get
        // forward deps.
        let mut deps = Vec::new();
        if !previous_failure && matches!(availability, OutputAvailability::Incomplete) {
            tracing::debug!("creating build step '{drv_path}");

            let step2 = step.clone();
            let mut stream = futures::StreamExt::map(
                tokio_stream::iter(input_drvs),
                |(input_path, relation)| {
                    let build = build.clone();
                    let step = step2.clone();
                    let finished_drvs = finished_drvs.clone();
                    let new_steps = new_steps.clone();
                    let new_runnable = new_runnable.clone();

                    async move {
                        Box::pin(self.create_step(
                            build,
                            input_path,
                            None,
                            Some((step, relation)),
                            finished_drvs,
                            new_steps,
                            new_runnable,
                        ))
                        .await
                    }
                },
            )
            .buffered(25);
            while let Some(result) = tokio_stream::StreamExt::next(&mut stream).await {
                match result {
                    CreateStepResult::None => (),
                    CreateStepResult::Valid(dep) => deps.push(dep),
                    CreateStepResult::PreviousFailure(step) => {
                        return CreateStepResult::PreviousFailure(step);
                    }
                }
            }
        }

        let outcome = {
            let mut new_runnable = new_runnable.write();
            attach_step(
                &step,
                availability,
                previous_failure,
                deps,
                &mut new_runnable,
            )
        };
        match outcome {
            AttachOutcome::PreviousFailure => CreateStepResult::PreviousFailure(step),
            AttachOutcome::Finished => {
                tracing::info!(
                    "create_step: {drv_path} already finished (outputs in store), skipping"
                );
                if let Some(fod_checker) = &self.fod_checker {
                    fod_checker.to_traverse(&drv_path);
                }
                finished_drvs.write().insert(drv_path.clone());
                CreateStepResult::None
            }
            AttachOutcome::PendingUpload(paths) => {
                tracing::info!(
                    "create_step: {drv_path} outputs valid locally, awaiting upload to remote store"
                );
                step.try_mark_upload_scheduled();
                let log_file = self.construct_log_file_path(&drv_path).await;
                self.uploader
                    .schedule_upload(
                        paths,
                        format!("log/{drv_path}"),
                        log_file,
                        Some(drv_path.clone()),
                    )
                    .await;
                new_steps.write().insert(step.clone());
                CreateStepResult::Valid(step)
            }
            AttachOutcome::Attached => {
                new_steps.write().insert(step.clone());
                CreateStepResult::Valid(step)
            }
        }
    }

    /// A pre-existing step whose outputs turned out to be all valid in the
    /// local store. Decide whether it counts as finished, applying the same
    /// upload gating as [`State::prefetch_step_facts`]: with presigned
    /// uploads builders fetch inputs from the remote binary cache, so the
    /// step only finishes once its outputs were uploaded there.
    async fn revalidate_locally_valid_step(
        &self,
        step: Arc<Step>,
        drv_path: &StorePath,
        finished_drvs: &parking_lot::RwLock<HashSet<StorePath>>,
    ) -> CreateStepResult {
        let output_paths = step.get_output_paths().unwrap_or_default();
        if let Some(missing) = self.query_missing_remote_outputs(output_paths).await
            && !missing.is_empty()
        {
            let paths: Vec<StorePath> = missing.values().filter_map(Clone::clone).collect();
            let gated = self.config.use_presigned_uploads();
            if step.try_mark_upload_scheduled() {
                let log_file = self.construct_log_file_path(drv_path).await;
                self.uploader
                    .schedule_upload(
                        paths,
                        format!("log/{drv_path}"),
                        log_file,
                        gated.then(|| drv_path.clone()),
                    )
                    .await;
            }
            if gated {
                // Builders fetch inputs from the remote cache; the step
                // stays unfinished until the upload completion event.
                return CreateStepResult::Valid(step);
            }
            // Builders import inputs from the queue runner's local
            // store: local validity is enough, the upload only fills
            // the cache.
        }
        finished_drvs.write().insert(drv_path.clone());
        complete_step(&step);
        CreateStepResult::None
    }

    /// IO phase of step creation: read the derivation, check local/remote
    /// output validity, try substitutes and look up cached failures. Must
    /// not mutate the step graph; that happens in [`attach_step`].
    #[allow(clippy::too_many_lines)]
    #[tracing::instrument(skip(self, build), fields(build_id = build.id, %drv_path))]
    async fn prefetch_step_facts(
        &self,
        build: &Arc<Build>,
        drv_path: &StorePath,
    ) -> Option<StepFacts> {
        let Some(drv) = self.read_derivation(drv_path).await.ok() else {
            tracing::warn!("create_step: could not query derivation {drv_path}, skipping");
            return None;
        };
        if let Some(fod_checker) = &self.fod_checker {
            fod_checker.add_ca_drv_parsed(drv_path, &drv);
        }

        if let Ok(system_type) = std::str::from_utf8(&drv.platform) {
            #[allow(clippy::cast_precision_loss)]
            self.metrics.observe_build_input_drvs(
                harmonia_store_derivation::derivation::DerivationInputs::from(&drv.inputs)
                    .drvs
                    .len() as f64,
                system_type,
            );
        }

        let use_substitutes = self.config.get_use_substitutes();
        let output_paths: BTreeMap<OutputName, Option<StorePath>> = drv
            .outputs
            .iter()
            .map(|(name, output)| {
                (
                    name.clone(),
                    output
                        .path(self.pool.store_dir(), &drv.name, name)
                        .ok()
                        .flatten(),
                )
            })
            .collect();
        let known_outputs = self
            .query_known_drv_outputs(drv_path)
            .await
            .unwrap_or_else(|e| {
                tracing::warn!("Could not query known outputs, continuing: {e}");
                BTreeMap::new()
            });
        // Outputs with None paths (CA floating) are always missing —
        // their path is unknown until the derivation is built.
        let missing_local_outputs: BTreeMap<OutputName, Option<StorePath>> = {
            let mut missing = BTreeMap::new();
            for (name, path) in &output_paths {
                match path {
                    Some(path) => {
                        if !self.is_valid_path(path).await.unwrap_or(false) {
                            missing.insert(name.clone(), Some(path.clone()));
                        }
                    }
                    None => {
                        // CA floating: output path unknown, definitely missing
                        missing.insert(name.clone(), None);
                    }
                }
            }
            missing
        };
        // Handle paths that aren't in the database (for resolution)
        // existing_local_outputs = output_paths - missing_local_outputs
        // unregistered_local_outputs = existing_local_outputs - known_outputs
        let unregistered_local_outputs = output_paths
            .iter()
            .filter(|(name, path)| {
                path.is_some()
                    && !missing_local_outputs.contains_key(name)
                    && !known_outputs.contains_key(name)
            })
            .map(|(name, path)| (name.clone(), path.clone()))
            .collect::<BTreeMap<_, _>>();
        if !unregistered_local_outputs.is_empty()
            && let Err(e) = crate::utils::make_local_step(
                &self.db,
                self.pool.store_dir(),
                build.id,
                drv_path,
                &unregistered_local_outputs,
            )
            .await
        {
            tracing::warn!("Failed to mark outputs as already found, continuing: {e}");
        }

        // Handle paths that aren't in the remote store (for pushing).
        let mut pending_upload: Option<Vec<StorePath>> = None;
        let missing_outputs = match self
            .query_missing_remote_outputs(output_paths.clone())
            .await
        {
            Some(mut missing) => {
                if !missing.is_empty() && missing_local_outputs.is_empty() {
                    // We have all paths locally, so we can just upload them to
                    // the remote store.
                    let missing_paths: Vec<StorePath> =
                        missing.values().filter_map(Clone::clone).collect();
                    if self.config.use_presigned_uploads() {
                        // Builders fetch their inputs from the remote cache, so
                        // the step must not count as finished before the upload
                        // completed. The caller schedules the upload when
                        // attaching the step.
                        pending_upload = Some(missing_paths);
                    } else {
                        // Builders import inputs from the queue runner's local
                        // store: local validity is enough, the upload only
                        // fills the cache.
                        let log_file = self.construct_log_file_path(drv_path).await;
                        self.uploader
                            .schedule_upload(
                                missing_paths,
                                format!("log/{drv_path}"),
                                log_file,
                                None,
                            )
                            .await;
                    }
                    missing.clear();
                }
                missing
            }
            None => {
                // Without a remote store, just check the local store.
                // Reuse missing_local_outputs which already includes None
                // (CA floating) paths as missing.
                missing_local_outputs.clone()
            }
        };

        // Same lookup as `check_cached_failure`, but from the prefetched
        // output paths so the step graph is not touched in this phase.
        let previous_failure = match self.db.get().await {
            Ok(mut conn) => conn
                .check_if_paths_failed(
                    self.pool.store_dir(),
                    &output_paths.values().flatten().cloned().collect::<Vec<_>>(),
                )
                .await
                .unwrap_or_default(),
            Err(_) => false,
        };
        if previous_failure {
            return Some(StepFacts {
                drv,
                availability: OutputAvailability::Incomplete,
                previous_failure: true,
            });
        }

        tracing::debug!("missing outputs: {missing_outputs:?}");
        let finished = if !missing_outputs.is_empty() && use_substitutes {
            use futures::stream::StreamExt as _;

            // Substitution falls back to the binary cache for paths the
            // local store is missing.
            let remote_store = self.first_s3_remote_store();
            let mut substituted = 0;
            let missing_outputs_len = missing_outputs.len();
            let mut stream = futures::StreamExt::map(tokio_stream::iter(missing_outputs), |o| {
                self.metrics.nr_substitutes_started.inc();
                crate::utils::substitute_output(
                    self.db.clone(),
                    self.pool.clone(),
                    o,
                    build.id,
                    drv_path,
                    remote_store.as_ref(),
                )
            })
            .buffer_unordered(10);
            while let Some(v) = tokio_stream::StreamExt::next(&mut stream).await {
                match v {
                    Ok(v) if v => {
                        self.metrics.nr_substitutes_succeeded.inc();
                        substituted += 1;
                    }
                    Ok(_) => {
                        self.metrics.nr_substitutes_failed.inc();
                    }
                    Err(e) => {
                        self.metrics.nr_substitutes_failed.inc();
                        tracing::warn!("Failed to substitute path: {e}");
                    }
                }
            }
            substituted == missing_outputs_len
        } else {
            // CA floating outputs have None paths — they must be built.
            missing_outputs.is_empty()
        };

        let availability = if let Some(paths) = pending_upload {
            OutputAvailability::PendingUpload(paths)
        } else if finished {
            OutputAvailability::Complete
        } else {
            OutputAvailability::Incomplete
        };
        Some(StepFacts {
            drv,
            availability,
            previous_failure: false,
        })
    }

    /// Lock guarding build step inserts for a build, sharded by build id.
    fn build_step_lock(&self, build_id: BuildID) -> &tokio::sync::Mutex<()> {
        let idx = usize::try_from(build_id.unsigned_abs()).unwrap_or_default();
        &self.build_step_locks[idx % BUILD_STEP_LOCK_SHARDS]
    }

    /// Check local store validity through the Nix `SQLite` database instead
    /// of the nix-daemon, so queue ingestion does not compete with NAR
    /// uploads for daemon connections.
    async fn is_valid_path(&self, path: &StorePath) -> Result<bool, StateError> {
        let local_db = self
            .local_db
            .as_ref()
            .ok_or(StateError::LocalNixDbUnavailable)?;
        Ok(local_db.is_valid_path(path).await?)
    }

    /// Output paths that a previously succeeded build step produced. These
    /// were uploaded to the binary cache, so no narinfo lookup is needed for
    /// them.
    #[tracing::instrument(skip(self, output_paths))]
    async fn query_succeeded_outputs(
        &self,
        output_paths: &BTreeMap<OutputName, Option<StorePath>>,
    ) -> HashSet<StorePath> {
        let paths: Vec<StorePath> = output_paths.values().flatten().cloned().collect();
        let res = match self.db.get().await {
            Ok(mut conn) => conn
                .query_succeeded_output_paths(self.pool.store_dir(), &paths)
                .await
                .map(|v| v.into_iter().collect()),
            Err(e) => Err(e),
        };
        res.unwrap_or_else(|e| {
            tracing::warn!("Could not query succeeded outputs, continuing: {e}");
            HashSet::new()
        })
    }

    /// The first configured S3 remote store, if any. Several scheduling
    /// paths only need a single S3 store to decide whether outputs already
    /// live in the binary cache.
    // TODO: check all remote stores
    fn first_s3_remote_store(&self) -> Option<binary_cache::S3BinaryCacheClient> {
        let r = self.remote_stores.read();
        r.iter().find_map(|s| match s {
            RemoteStoreBackend::S3(s) => Some(s.clone()),
            RemoteStoreBackend::NixCopy(_) => None,
        })
    }

    /// Database-first version of
    /// [`binary_cache::S3BinaryCacheClient::query_missing_remote_outputs`].
    /// Returns `None` when no S3 store is configured.
    ///
    /// Outputs of previously succeeded build steps were uploaded to the
    /// binary cache, so they can be treated as present without a narinfo
    /// request. Always go through this rather than calling the remote store
    /// directly, so the database short-circuit is never skipped.
    async fn query_missing_remote_outputs(
        &self,
        output_paths: BTreeMap<OutputName, Option<StorePath>>,
    ) -> Option<BTreeMap<OutputName, Option<StorePath>>> {
        let remote_store = self.first_s3_remote_store()?;
        let db_known = self.query_succeeded_outputs(&output_paths).await;
        let mut unknown_outputs = output_paths;
        unknown_outputs.retain(|_, path| path.as_ref().is_none_or(|p| !db_known.contains(p)));
        Some(
            remote_store
                .query_missing_remote_outputs(unknown_outputs)
                .await,
        )
    }

    #[tracing::instrument(skip(self))]
    async fn query_known_drv_outputs(
        &self,
        drv_path: &StorePath,
    ) -> Result<BTreeMap<OutputName, StorePath>, db::Error> {
        let mut db = self.db.get().await?;
        let mut tx = db.begin_transaction().await?;
        tx.find_build_step_outputs(self.pool.store_dir(), drv_path)
            .await
    }

    #[tracing::instrument(skip(self, step), ret, level = "debug")]
    async fn check_cached_failure(&self, step: Arc<Step>) -> bool {
        let Some(drv_outputs) = step.get_output_paths() else {
            return false;
        };

        let Ok(mut conn) = self.db.get().await else {
            return false;
        };

        conn.check_if_paths_failed(
            self.pool.store_dir(),
            &drv_outputs.values().flatten().cloned().collect::<Vec<_>>(),
        )
        .await
        .unwrap_or_default()
    }

    #[tracing::instrument(skip(self, build), fields(build_id=build.id), err)]
    async fn handle_cached_build(&self, build: Arc<Build>) -> Result<(), StateError> {
        let res = self.get_build_output_cached(&build.drv_path).await?;

        {
            let mut db = self.db.get().await?;
            let mut tx = db.begin_transaction().await?;

            tracing::info!("marking build {} as succeeded (cached)", build.id);
            let now = jiff::Timestamp::now().as_second();
            tx.mark_succeeded_build(
                get_mark_build_sccuess_data(&build, &res),
                true,
                i32::try_from(now)?, // TODO
                i32::try_from(now)?, // TODO
                self.pool.store_dir(),
            )
            .await?;
            self.metrics.nr_builds_done.inc();

            tx.notify_build_finished(build.id, &[]).await?;
            tx.commit().await?;
        }
        build.set_finished_in_db(true);

        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    async fn get_build_output_cached(
        &self,
        drv_path: &StorePath,
    ) -> Result<BuildOutput, StateError> {
        let drv = self.read_derivation(drv_path).await?;

        let output_paths: BTreeMap<OutputName, Option<StorePath>> = drv
            .outputs
            .iter()
            .map(|(name, output)| {
                (
                    name.clone(),
                    output
                        .path(self.pool.store_dir(), &drv.name, name)
                        .ok()
                        .flatten(),
                )
            })
            .collect();
        {
            let mut db = self.db.get().await?;
            for out_path in output_paths.values() {
                let Some(out_path) = out_path else {
                    continue;
                };
                let Some(db_build_output) = db
                    .get_build_output_for_path(self.pool.store_dir(), out_path)
                    .await?
                else {
                    continue;
                };
                let build_id = db_build_output.id;
                let Ok(mut res): Result<BuildOutput, _> = db_build_output.try_into() else {
                    continue;
                };

                res.products = db
                    .get_build_products_for_build_id(build_id, self.pool.store_dir())
                    .await?;
                res.metrics = db
                    .get_build_metrics_for_build_id(build_id)
                    .await?
                    .into_iter()
                    .collect();

                return Ok(res);
            }
        }

        let default_store: std::path::PathBuf = self.pool.store_dir().to_string().into();
        let real_dir = self.real_store_dir.as_deref().unwrap_or(&default_store);
        let build_output = BuildOutput::new(&self.pool, real_dir, output_paths).await?;

        if let Ok(platform) = std::str::from_utf8(&drv.platform) {
            #[allow(clippy::cast_precision_loss)]
            self.metrics
                .observe_build_closure_size(build_output.closure_size as f64, platform);
        }

        Ok(build_output)
    }

    #[allow(unused)]
    fn add_root(&self, store_path: &StorePath) -> std::io::Result<()> {
        let roots_dir = self.config.get_roots_dir();
        // Inline filesystem symlink for GC roots
        let link_path = roots_dir.join(store_path.to_string());
        let store_path_full = format!("{}/{store_path}", self.pool.store_dir());
        fs_err::os::unix::fs::symlink(&store_path_full, &link_path)
    }

    async fn abort_unsupported(&self) {
        let runnable = self.steps.clone_runnable();
        let now = jiff::Timestamp::now();

        let mut aborted = HashSet::new();
        let mut count = 0;

        let max_unsupported_time = self.config.get_max_unsupported_time();
        for step in &runnable {
            let supported = self.machines.support_step(step);
            if supported {
                step.set_last_supported_now();
                continue;
            }

            count += 1;
            if (now - step.get_last_supported())
                .total(jiff::Unit::Second)
                .unwrap_or_default()
                < max_unsupported_time.as_secs_f64()
            {
                continue;
            }

            let drv = step.get_drv_path();
            let system = step.get_system();
            tracing::error!("aborting unsupported build step '{drv}' (type '{system:?}')",);

            aborted.insert(step.clone());

            let mut dependents = HashSet::new();
            let mut steps = HashSet::new();
            step.get_dependents(&mut dependents, &mut steps);
            // Maybe the step got cancelled.
            if dependents.is_empty() {
                continue;
            }

            // Find the build that has this step as the top-level (if any).
            let Some(build) = dependents
                .iter()
                .find(|b| &b.drv_path == drv)
                .or_else(|| dependents.iter().next())
            else {
                // this should never happen, as we checked is_empty above and fallback is just any build
                continue;
            };

            let mut job = machine::Job::new(build.id, drv.to_owned());
            job.result.set_start_and_stop(now);
            job.result.step_status = BuildStatus::Unsupported;
            job.result.error_msg = Some(format!(
                "unsupported system type '{}'",
                system.unwrap_or(String::new())
            ));
            if let Err(e) = self.inner_fail_job(drv, None, job, step.clone()).await {
                tracing::error!("Failed to fail step drv={drv} e={e}");
            }
        }

        {
            for step in &aborted {
                self.queues.remove_job_by_path(step.get_drv_path()).await;
            }
            self.queues.remove_all_weak_pointer().await;
        }
        self.metrics.nr_unsupported_steps.set(count);
        self.metrics
            .nr_unsupported_steps_aborted
            .inc_by(aborted.len() as u64);
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn drv_path(name: &str) -> StorePath {
        StorePath::from_base_path(&format!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-{name}.drv")).unwrap()
    }

    /// A parent step and its dep, registered like `create_step` does it:
    /// the child carries the parent as rdep before the parent attaches.
    fn parent_and_child(steps: &Steps) -> (Arc<Step>, Arc<Step>) {
        let (parent, _) = steps.create(&drv_path("parent"), None, None);
        let (child, _) = steps.create(
            &drv_path("child"),
            None,
            Some((&parent, drv::OutputNameChain::default())),
        );
        (parent, child)
    }

    /// Regression test for a lost wakeup: the dep finishes and runs its
    /// `make_rdeps_runnable` pass between prefetch and attach. The parent
    /// must still come out runnable instead of keeping a finished dep.
    #[test]
    fn attach_skips_dep_that_finished_after_prefetch() {
        let steps = Steps::new();
        let (parent, child) = parent_and_child(&steps);

        child.set_finished(true);
        child.make_rdeps_runnable();

        let mut new_runnable = HashSet::new();
        let outcome = attach_step(
            &parent,
            OutputAvailability::Incomplete,
            false,
            vec![child],
            &mut new_runnable,
        );
        assert!(matches!(outcome, AttachOutcome::Attached));
        assert_eq!(parent.get_deps_size(), 0);
        assert!(new_runnable.contains(&parent));
    }

    #[test]
    fn dep_finishing_after_attach_wakes_parent() {
        let steps = Steps::new();
        let (parent, child) = parent_and_child(&steps);

        let mut new_runnable = HashSet::new();
        let outcome = attach_step(
            &parent,
            OutputAvailability::Incomplete,
            false,
            vec![child.clone()],
            &mut new_runnable,
        );
        assert!(matches!(outcome, AttachOutcome::Attached));
        assert!(new_runnable.is_empty());
        assert!(!parent.get_runnable());
        assert_eq!(parent.get_deps_size(), 1);

        child.set_finished(true);
        child.make_rdeps_runnable();
        assert_eq!(parent.get_deps_size(), 0);
        assert!(parent.get_runnable());
    }

    /// Regression test for premature dispatch: a dep whose outputs are
    /// valid locally but
    /// missing in the remote binary cache must keep its rdeps blocked until
    /// the upload completion event, and must not be dispatchable itself.
    #[test]
    fn pending_upload_gates_parent_until_upload_completes() {
        let steps = Steps::new();
        let (parent, child) = parent_and_child(&steps);

        let mut new_runnable = HashSet::new();
        let outcome = attach_step(
            &child,
            OutputAvailability::PendingUpload(Vec::new()),
            false,
            Vec::new(),
            &mut new_runnable,
        );
        assert!(matches!(outcome, AttachOutcome::PendingUpload(_)));
        assert!(!child.get_finished());
        assert!(new_runnable.is_empty());

        let outcome = attach_step(
            &parent,
            OutputAvailability::Incomplete,
            false,
            vec![child.clone()],
            &mut new_runnable,
        );
        assert!(matches!(outcome, AttachOutcome::Attached));
        assert!(new_runnable.is_empty());
        assert!(!parent.get_runnable());

        // Upload completion event.
        complete_step(&child);
        assert!(child.get_finished());
        assert!(parent.get_runnable());
    }

    /// A step revalidating as complete must wake rdeps that already wait on
    /// it; the old revalidation path never called `make_rdeps_runnable`.
    #[test]
    fn complete_step_wakes_existing_rdeps() {
        let steps = Steps::new();
        let (parent, child) = parent_and_child(&steps);

        let mut new_runnable = HashSet::new();
        attach_step(
            &parent,
            OutputAvailability::Incomplete,
            false,
            vec![child.clone()],
            &mut new_runnable,
        );
        assert!(!parent.get_runnable());

        let outcome = attach_step(
            &child,
            OutputAvailability::Complete,
            false,
            Vec::new(),
            &mut new_runnable,
        );
        assert!(matches!(outcome, AttachOutcome::Finished));
        assert!(parent.get_runnable());
    }
}

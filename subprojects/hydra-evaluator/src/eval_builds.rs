//! Filing the builds an evaluation needs with Hydra.
//!
//! Evaluating a jobset sometimes requires a build first: the expression
//! reads a derivation's output in order to say what the jobs are, so
//! nix-eval-jobs cannot produce them until that derivation is realised.
//! Left alone it builds on the evaluator host, which is the one machine
//! in a Hydra deployment with no build capacity budgeted for it — and
//! with none of the logging, scheduling or machine selection the queue
//! runner exists to provide.
//!
//! So the evaluator hosts a [`daemon_server`] of its own for the duration
//! of each evaluation and points the evaluation's `NIX_REMOTE` at it. The
//! store operations nix-eval-jobs performs then arrive here, and the
//! builds among them become Hydra builds like any other.
//!
//! Hosting the server in-process rather than running a shared daemon is
//! what makes the attribution possible: the socket exists for exactly one
//! evaluation, so anything arriving on it is known to belong to that
//! evaluation's jobset.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use daemon_server::{BuildRequest, BuildWaiter, DaemonServer, HydraDaemonHandler, SubmitBuild};
use db::models::BuildID;
use harmonia_store_path::StoreDir;
use tokio::sync::{Mutex, oneshot};

use crate::queries::JobsetQueries as _;

/// Settings for filing an evaluation's builds with Hydra,
/// read from `hydra.conf`.
#[derive(Debug, Clone)]
pub(crate) struct EvalBuildsConfig {
    /// Directory the per-evaluation sockets are created in.
    pub(crate) socket_dir: PathBuf,
    /// Unix socket of the nix-daemon reads and uploads are proxied to.
    pub(crate) upstream_socket: String,
    /// Store the evaluation and the builders share.
    pub(crate) store_dir: StoreDir,
    /// Query string from the upstream URI, handed on to the evaluation
    /// verbatim so it reads the store the way the upstream daemon does.
    pub(crate) store_params: String,
}

/// Default upstream: the system nix-daemon on the default store.
const DEFAULT_UPSTREAM: &str = "unix:///nix/var/nix/daemon-socket/socket?store=/nix/store";

/// What a jobset evaluation may do when it needs a derivation built
/// before it can proceed, from `builds_during_evaluation` in hydra.conf.
///
/// One setting rather than a permission plus a routing switch, so that
/// "route through Hydra, but forbid building" — which reads as enabled
/// and does nothing — cannot be written down.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum BuildsDuringEvaluation {
    /// Refuse. nix-eval-jobs fails the evaluation instead of building.
    Disallowed,
    /// Build on whichever machine is running the evaluation.
    ViaEvaluator,
    /// File the build in Hydra and let the queue runner place it.
    ViaHydra,
}

impl BuildsDuringEvaluation {
    pub(crate) const KEY: &'static str = "builds_during_evaluation";

    pub(crate) fn from_hydra_config(config: &crate::config::HydraConfig) -> Self {
        match config.get_str(Self::KEY) {
            None | Some("disallowed") => Self::Disallowed,
            Some("via-evaluator") => Self::ViaEvaluator,
            Some("via-hydra") => Self::ViaHydra,
            Some(other) => {
                // Refusing is the safe reading of a typo: building during
                // evaluation lets a jobset run builders while it is being
                // read, which is why it is off by default.
                tracing::warn!(
                    "{} is {other:?}, which is not one of disallowed, \
                     via-evaluator or via-hydra; refusing to build during \
                     evaluation",
                    Self::KEY,
                );
                Self::Disallowed
            }
        }
    }
}

impl EvalBuildsConfig {
    /// Read the config, returning `None` unless evaluations should file
    /// the builds they need with Hydra.
    pub(crate) fn from_hydra_config(config: &crate::config::HydraConfig) -> Option<Self> {
        if BuildsDuringEvaluation::from_hydra_config(config) != BuildsDuringEvaluation::ViaHydra {
            return None;
        }
        let upstream = config
            .get_str("evaluation_upstream_daemon")
            .unwrap_or(DEFAULT_UPSTREAM);
        let (upstream_socket, store_dir, store_params) = match parse_upstream(upstream) {
            Ok(parsed) => parsed,
            Err(e) => {
                tracing::warn!(
                    "evaluation_upstream_daemon {upstream:?} is unusable, not scheduling builds during evaluation: {e}"
                );
                return None;
            }
        };
        Some(Self {
            socket_dir: socket_dir(config),
            upstream_socket,
            store_dir,
            store_params,
        })
    }
}

/// Where to put the per-evaluation sockets.
///
/// Defaults under `HYDRA_DATA`, which every Hydra service already has
/// and can write to, so enabling this needs no deployment-side change
/// to grant the evaluator a directory of its own.
fn socket_dir(config: &crate::config::HydraConfig) -> PathBuf {
    if let Some(dir) = config.get_str("evaluation_daemon_socket_dir") {
        return PathBuf::from(dir);
    }
    let base = std::env::var("HYDRA_DATA").unwrap_or_else(|_| "/tmp".to_owned());
    PathBuf::from(base).join("evaluation-sockets")
}

/// Split a `unix://<socket>?store=<dir>` URI into the socket, the store
/// it serves, and the parameters as written.
///
/// The store dir has to travel with the socket rather than be assumed:
/// a `unix://` daemon says nothing about which store it serves, and
/// reading a path it returns against the wrong store dir fails to
/// parse. Other Hydra services take the same `?store=` parameter.
///
/// The parameters are kept whole because they can say more than the
/// store dir — `root=` for a chroot store, say — and an evaluation
/// reading through this daemon has to resolve paths the same way the
/// upstream does or it will look for them in the wrong place.
fn parse_upstream(uri: &str) -> Result<(String, StoreDir, String), UpstreamError> {
    let rest = uri
        .strip_prefix("unix://")
        .ok_or_else(|| UpstreamError::NotUnixUri(uri.to_owned()))?;
    let (socket, query) = rest.split_once('?').unwrap_or((rest, ""));
    let store = query
        .split('&')
        .find_map(|param| param.strip_prefix("store="))
        .ok_or_else(|| UpstreamError::NoStoreParam(uri.to_owned()))?;
    let store_dir = StoreDir::new(store).map_err(|e| UpstreamError::StoreDir(e.to_string()))?;
    Ok((socket.to_owned(), store_dir, query.to_owned()))
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum UpstreamError {
    #[error("{0} is not a unix:// daemon URI")]
    NotUnixUri(String),

    #[error("{0} has no ?store= parameter saying which store the daemon serves")]
    NoStoreParam(String),

    #[error("invalid store directory: {0}")]
    StoreDir(String),
}

/// Attributes every build to the jobset whose evaluation asked for it,
/// and remembers which builds those were.
///
/// One of these exists per running evaluation, so `jobset_id` is not a
/// guess: the socket it serves was created for that evaluation alone.
/// The ids are kept because the evaluation's own `JobsetEvals` row does
/// not exist yet — it is written when evaluation finishes — so the
/// builds cannot be recorded as members of it until afterwards.
#[derive(Debug, Clone)]
struct JobsetSubmitter {
    jobset_id: i32,
    builds: Arc<Mutex<Vec<BuildID>>>,
}

impl SubmitBuild for JobsetSubmitter {
    async fn submit(
        &self,
        tx: &mut db::Transaction<'_>,
        request: BuildRequest<'_>,
    ) -> Result<BuildID, db::Error> {
        let build_id = tx
            .insert_daemon_build(
                self.jobset_id,
                request.nix_name,
                request.drv_path,
                request.system,
            )
            .await?;
        self.builds.lock().await.push(build_id);
        Ok(build_id)
    }
}

/// A daemon serving one evaluation. Dropping it shuts the daemon down
/// and unlinks the socket, so an evaluation that dies for any reason —
/// finished, killed, panicked — cannot leave one behind.
#[derive(Debug)]
pub(crate) struct EvalDaemon {
    jobset_id: i32,
    socket_path: PathBuf,
    shutdown: Option<oneshot::Sender<()>>,
    builds: Arc<Mutex<Vec<BuildID>>>,
    /// Newest evaluation of this jobset when the daemon started, so a
    /// newer one afterwards can be recognised as this run's.
    eval_before: Option<i32>,
}

impl EvalDaemon {
    /// Start a daemon for `jobset_id` and wait for its socket to exist.
    ///
    /// The socket has to be listening before nix-eval-jobs is told to use
    /// it, or the first store operation of the evaluation races the bind.
    pub(crate) async fn start(
        config: &EvalBuildsConfig,
        db: &db::Database,
        jobset_id: i32,
    ) -> Result<Self, StartError> {
        let socket_path = config.socket_dir.join(format!("eval-{jobset_id}.sock"));
        let eval_before = db
            .get()
            .await
            .map_err(StartError::Waiter)?
            .get_latest_eval_id(jobset_id)
            .await
            .map_err(|e| StartError::Waiter(e.into()))?;
        let builds = Arc::new(Mutex::new(Vec::new()));
        let waiter = BuildWaiter::start(db).await.map_err(StartError::Waiter)?;
        let handler = HydraDaemonHandler::new(
            config.store_dir.clone(),
            db.clone(),
            &config.upstream_socket,
            waiter,
            JobsetSubmitter {
                jobset_id,
                builds: Arc::clone(&builds),
            },
        );
        let server = DaemonServer::new(handler, socket_path.clone(), config.store_dir.clone());

        let (shutdown, shutdown_rx) = oneshot::channel();
        let serve_path = socket_path.clone();
        tokio::spawn(async move {
            // A closed channel means the EvalDaemon was dropped, which is
            // the same instruction as an explicit shutdown.
            let stop = async {
                let _ = shutdown_rx.await;
            };
            if let Err(e) = server.serve_until(stop).await {
                tracing::error!("evaluation daemon on {serve_path:?} stopped: {e}");
            }
        });

        wait_for_socket(&socket_path).await?;
        Ok(Self {
            jobset_id,
            socket_path,
            shutdown: Some(shutdown),
            builds,
            eval_before,
        })
    }

    /// Record the builds as members of the evaluation they were made for.
    ///
    /// Called once the evaluation has finished, because that is when its
    /// `JobsetEvals` row comes into being: while the build was running
    /// there was no evaluation to point at.
    ///
    /// An evaluation that produced no new row — it failed, or nothing had
    /// changed since last time — leaves the builds attached to the jobset
    /// but to no evaluation. They are left that way rather than deleted:
    /// the work really did happen, and its outputs are worth keeping.
    pub(crate) async fn record_members(&self, db: &db::Database) {
        let build_ids = self.builds.lock().await.clone();
        if build_ids.is_empty() {
            return;
        }
        if let Err(e) = self.try_record_members(db, &build_ids).await {
            tracing::warn!(
                "could not record {} build(s) for the evaluation \
                 of jobset#{}: {e}",
                build_ids.len(),
                self.jobset_id,
            );
        }
    }

    async fn try_record_members(
        &self,
        db: &db::Database,
        build_ids: &[BuildID],
    ) -> Result<(), db::Error> {
        let mut conn = db.get().await?;
        let eval_id = conn.get_latest_eval_id(self.jobset_id).await?;
        match eval_id {
            Some(eval_id) if Some(eval_id) != self.eval_before => {
                conn.add_builds_for_evaluation(eval_id, build_ids).await?;
                tracing::debug!(
                    "recorded {} build(s) made for evaluation {eval_id}",
                    build_ids.len(),
                );
            }
            _ => {
                tracing::debug!(
                    "evaluation of jobset#{} produced no new evaluation; \
                     leaving {} build(s) unattached",
                    self.jobset_id,
                    build_ids.len(),
                );
            }
        }
        Ok(())
    }

    /// `NIX_REMOTE` value pointing an evaluation at this daemon.
    ///
    /// `unix://` ignores `NIX_STORE_DIR` when deciding its logical store
    /// path, so the store has to travel as a URL parameter or the client
    /// and the daemon disagree about what the paths mean. The upstream's
    /// parameters are passed on unchanged, so the evaluation resolves
    /// paths exactly as the daemon behind us does.
    pub(crate) fn nix_remote(&self, store_params: &str) -> String {
        format!("unix://{}?{store_params}", self.socket_path.display())
    }
}

impl Drop for EvalDaemon {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
    }
}

async fn wait_for_socket(path: &Path) -> Result<(), StartError> {
    for _ in 0..100 {
        if path.exists() {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    Err(StartError::SocketNeverAppeared(path.to_path_buf()))
}

#[derive(Debug, thiserror::Error)]
pub(crate) enum StartError {
    #[error("could not listen for finished builds: {0}")]
    Waiter(#[source] db::Error),

    #[error("evaluation daemon socket never appeared at {0}")]
    SocketNeverAppeared(PathBuf),
}

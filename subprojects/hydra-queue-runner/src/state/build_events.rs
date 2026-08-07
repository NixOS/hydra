//! Outbound build lifecycle events.
//!
//! ofborg creates builds through `CreateBuild` and then needs to know what
//! became of them so it can report progress back onto the pull request. The
//! queue-runner already writes everything it knows to the database, but ofborg
//! has no database access — and polling would neither scale nor tell it which
//! machine a build landed on.
//!
//! So the runner fans out an event whenever an ofborg build changes state.
//! Only jobsets marked `is_ofborg` are ever emitted: everything else would be
//! both a large volume of traffic nobody asked for and data a build-sponsor
//! integration has no business seeing.

use std::sync::Arc;

use db::models::{BuildID, BuildStatus, StepStatus};
use nix_utils::BaseStore as _;

use super::JobsetID;

/// Events are dropped for a subscriber that falls this far behind. It is then
/// told it lagged rather than silently missing updates.
const CHANNEL_CAPACITY: usize = 4096;

#[derive(Debug, Clone)]
pub enum BuildEventKind {
    Queued,
    Running {
        machine: String,
        step_status: StepStatus,
    },
    Finished {
        status: BuildStatus,
        /// `None` when no builder was involved, e.g. a cached build or one
        /// failed by a dependency.
        machine: Option<String>,
    },
}

#[derive(Debug, Clone)]
pub struct BuildEvent {
    pub build_id: BuildID,
    pub jobset_id: JobsetID,
    pub drv_path: String,
    pub kind: BuildEventKind,
}

pub struct BuildEvents {
    tx: tokio::sync::broadcast::Sender<Arc<BuildEvent>>,
}

impl std::fmt::Debug for BuildEvents {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BuildEvents")
            .field("subscribers", &self.tx.receiver_count())
            .finish()
    }
}

impl Default for BuildEvents {
    fn default() -> Self {
        Self::new()
    }
}

impl BuildEvents {
    #[must_use]
    pub fn new() -> Self {
        let (tx, _rx) = tokio::sync::broadcast::channel(CHANNEL_CAPACITY);
        Self { tx }
    }

    #[must_use]
    pub fn subscribe(&self) -> tokio::sync::broadcast::Receiver<Arc<BuildEvent>> {
        self.tx.subscribe()
    }

    #[must_use]
    pub fn subscriber_count(&self) -> usize {
        self.tx.receiver_count()
    }

    /// Publish an event to every subscriber.
    ///
    /// Callers must have established that the build belongs to an ofborg
    /// jobset. Having no subscribers is the normal case and not an error.
    pub fn emit(&self, event: BuildEvent) {
        tracing::debug!("build event: {event:?}");
        let _ = self.tx.send(Arc::new(event));
    }

    /// Convenience for the common shape: emit for a build, if it is an ofborg
    /// one.
    pub fn emit_for_build(
        &self,
        build: &super::Build,
        store: &nix_utils::LocalStore,
        kind: BuildEventKind,
    ) {
        if !build.jobset.is_ofborg {
            return;
        }

        self.emit(BuildEvent {
            build_id: build.id,
            jobset_id: build.jobset_id,
            drv_path: store.print_store_path(&build.drv_path),
            kind,
        });
    }
}

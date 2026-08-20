#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    unused_qualifications
)]

//! A nix-daemon protocol endpoint that turns build requests into Hydra
//! builds.
//!
//! A client that speaks the nix daemon protocol — `nix-build`,
//! `nix-store --realise`, or `nix-eval-jobs` needing a derivation built
//! before it can carry on evaluating — asks its store to realise a
//! derivation and blocks until it is done. Pointing such a client at a
//! server built from this crate makes that request land in Hydra's
//! `Builds` table instead of building locally, so the queue runner and
//! its builders do the work. Read operations and store uploads are
//! proxied to an upstream nix-daemon.
//!
//! What the request *means* in Hydra's data model is left to the caller
//! via [`SubmitBuild`]: a standalone daemon has no context and files
//! builds under an ad-hoc jobset, while a caller that hosts the server
//! itself (an evaluator, say) knows which evaluation the build belongs
//! to and can record it accordingly.

mod handler;
mod server;
mod submit;
mod waiter;

pub use handler::HydraDaemonHandler;
pub use server::DaemonServer;
pub use submit::{BuildRequest, SubmitBuild};
pub use waiter::BuildWaiter;

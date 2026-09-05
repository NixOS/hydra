#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    clippy::pedantic,
    clippy::expect_used,
    clippy::unwrap_used,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    missing_copy_implementations,
    unused_qualifications
)]
#![allow(clippy::missing_errors_doc)]

//! Evaluating jobsets, in two halves that meet in the database.
//!
//! [`evaluator`] decides when a jobset is due, fetches its inputs and queues
//! a build that will run `nix-eval-jobs`. [`evaluate::complete`] reads that
//! build's output back and turns it into builds of the jobset. Nothing joins
//! them but the rows: the build between them can take hours and outlive
//! either process.

pub mod config;
pub mod eval_build;
pub mod evaluate;
pub mod evaluator;
pub mod fetcher;
pub mod ingest;
pub mod inputs;
pub mod nix_eval_jobs;
pub mod queries;
pub mod store_paths;

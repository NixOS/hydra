//! The programs the evaluator runs, found once at startup.
//!
//! Each is named by its own variable (see [`hydra_programs`]), so a missing
//! one stops the evaluator before it starts work, rather than failing every
//! evaluation that reaches it.

use hydra_programs::{NixPath, Program as _, program};

program!(pub(crate) FetchInputPath, "hydra-fetch-input");
program!(
    pub(crate) PrepareDeclarativeJobsetPath,
    "hydra-prepare-declarative-jobset"
);
program!(pub(crate) NixEvalJobsPath, "nix-eval-jobs");
program!(pub(crate) NixStorePath, "nix-store");

#[derive(Debug)]
pub(crate) struct Programs {
    pub fetch_input: FetchInputPath,
    pub prepare_declarative_jobset: PrepareDeclarativeJobsetPath,
    pub nix_eval_jobs: NixEvalJobsPath,
    pub nix: NixPath,
    pub nix_store: NixStorePath,
}

impl Programs {
    pub(crate) fn locate() -> Result<Self, hydra_programs::Missing> {
        Ok(Self {
            fetch_input: FetchInputPath::locate()?,
            prepare_declarative_jobset: PrepareDeclarativeJobsetPath::locate()?,
            nix_eval_jobs: NixEvalJobsPath::locate()?,
            nix: NixPath::locate()?,
            nix_store: NixStorePath::locate()?,
        })
    }
}

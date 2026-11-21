//! The programs submitting an evaluation runs, found once at startup.
//!
//! Each is named by its own variable (see [`hydra_programs`]), so a missing
//! one stops the submitter before it starts work, rather than failing every
//! submission that reaches it.

use hydra_programs::{NixPath, Program as _, program};

program!(pub(crate) FetchInputPath, "hydra-fetch-input");
program!(
    pub(crate) PrepareDeclarativeJobsetPath,
    "hydra-prepare-declarative-jobset"
);
program!(pub(crate) NixEvalJobsPath, "nix-eval-jobs");
program!(pub(crate) NixInstantiatePath, "nix-instantiate");
program!(pub(crate) NixStorePath, "nix-store");

#[derive(Debug)]
pub(crate) struct Programs {
    pub fetch_input: FetchInputPath,
    pub prepare_declarative_jobset: PrepareDeclarativeJobsetPath,
    /// Not run here: the evaluation build runs it, so this is the path the
    /// derivation names.
    pub nix_eval_jobs: NixEvalJobsPath,
    pub nix: NixPath,
    pub nix_instantiate: NixInstantiatePath,
    pub nix_store: NixStorePath,
}

impl Programs {
    pub(crate) fn locate() -> Result<Self, hydra_programs::Missing> {
        Ok(Self {
            fetch_input: FetchInputPath::locate()?,
            prepare_declarative_jobset: PrepareDeclarativeJobsetPath::locate()?,
            nix_eval_jobs: NixEvalJobsPath::locate()?,
            nix: NixPath::locate()?,
            nix_instantiate: NixInstantiatePath::locate()?,
            nix_store: NixStorePath::locate()?,
        })
    }
}

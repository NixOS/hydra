//! What the evaluator is configured with.
//!
//! Its own file, as the queue runner and the builder have theirs.
//! `Hydra::Config` warns about any of these settings left in `hydra.conf`.

#[derive(Debug, thiserror::Error)]
pub(crate) enum ConfigError {
    #[error("reading {path}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },

    #[error("parsing {path}")]
    Toml {
        path: String,
        #[source]
        source: toml::de::Error,
    },
}

#[derive(Debug, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HydraConfig {
    /// Whether jobsets may import from derivations. Off unless asked for,
    /// because it lets an evaluation demand builds.
    #[serde(default)]
    allow_import_from_derivation: bool,

    /// Whether non-flake jobsets may be evaluated without `restrict-eval`.
    #[serde(default)]
    allow_unrestricted_eval: bool,

    /// How many `nix-eval-jobs` workers to run.
    #[serde(default = "default_workers")]
    evaluator_workers: u64,

    /// The memory each of them may use, in MiB, before it is restarted.
    #[serde(default = "default_max_memory_size")]
    evaluator_max_memory_size: u64,

    /// How many builds an evaluation may run locally, which matters for
    /// import-from-derivation.
    #[serde(default = "default_max_jobs")]
    evaluator_max_jobs: u64,

    /// What an evaluation build needs of the machine that runs it. Adding
    /// paths to the store while building is what evaluating does, which under
    /// a sandbox means `recursive-nix`.
    #[serde(default = "default_system_features")]
    evaluation_build_system_features: String,

    /// The store an evaluation build instantiates into, when `recursive-nix`
    /// is not there to configure its Nix for it. Must be the builder's store,
    /// so it is configuration rather than anything derivable here.
    #[serde(default)]
    evaluation_build_store_uri: Option<String>,

    /// How many seconds an evaluation may run. It is the evaluation build's
    /// timeout, so the build is killed and the evaluation fails.
    #[serde(default = "default_eval_timeout")]
    eval_timeout: u64,

    /// Where to fetch a build's output from when a `build` or `sysbuild`
    /// input names one this machine does not have. Unset means the store is
    /// expected to have everything already.
    #[serde(default)]
    eval_substituter: Option<String>,

    /// Where to root the evaluated derivations. This must be the
    /// `gc_roots_dir` of `hydra.conf`, which `hydra-update-gc-roots` tidies.
    /// Unset means `<state dir>/gcroots/per-user/$LOGNAME/hydra-roots`, as for
    /// the queue runner.
    ///
    /// Only `hydra-process-evaluation` reads it, since the derivations are
    /// known once an evaluation is processed; it is accepted here because the
    /// file is shared and unknown keys are refused.
    #[serde(default)]
    #[expect(dead_code, reason = "read by `hydra-process-evaluation`")]
    roots_dir: Option<std::path::PathBuf>,
}

fn default_workers() -> u64 {
    1
}

fn default_max_memory_size() -> u64 {
    4096
}

fn default_max_jobs() -> u64 {
    1
}

fn default_system_features() -> String {
    "recursive-nix".to_owned()
}

fn default_eval_timeout() -> u64 {
    3600
}

impl HydraConfig {
    /// Read the file, or take the defaults if it is not there.
    ///
    /// Absent is fine -- every setting has a default -- but present and
    /// unreadable is not, since that is a configuration someone wrote and
    /// expects to be in effect.
    pub(crate) fn load(path: &str) -> Result<Self, ConfigError> {
        let contents = match fs_err::read_to_string(path) {
            Ok(contents) => contents,
            // Parsed as empty, so the serde defaults apply.
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                tracing::info!("no configuration at {path}, using defaults");
                String::new()
            }
            Err(source) => {
                return Err(ConfigError::Io {
                    path: path.to_owned(),
                    source,
                });
            }
        };

        toml::from_str(&contents).map_err(|source| ConfigError::Toml {
            path: path.to_owned(),
            source,
        })
    }

    pub(crate) fn allow_import_from_derivation(&self) -> bool {
        self.allow_import_from_derivation
    }

    pub(crate) fn allow_unrestricted_eval(&self) -> bool {
        self.allow_unrestricted_eval
    }

    pub(crate) fn evaluator_workers(&self) -> u64 {
        self.evaluator_workers
    }

    pub(crate) fn evaluator_max_memory_size(&self) -> u64 {
        self.evaluator_max_memory_size
    }

    pub(crate) fn evaluator_max_jobs(&self) -> u64 {
        self.evaluator_max_jobs
    }

    pub(crate) fn evaluation_build_system_features(&self) -> &str {
        &self.evaluation_build_system_features
    }

    pub(crate) fn evaluation_build_store_uri(&self) -> Option<&str> {
        self.evaluation_build_store_uri.as_deref()
    }

    pub(crate) fn eval_substituter(&self) -> Option<&str> {
        self.eval_substituter.as_deref()
    }

    pub(crate) fn eval_timeout(&self) -> u64 {
        self.eval_timeout
    }
}

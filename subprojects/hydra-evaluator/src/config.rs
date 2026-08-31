//! What the evaluator is configured with.
//!
//! Its own file, as the queue runner and the builder have theirs.

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

#[derive(Debug, Default, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct HydraConfig {
    /// Whether jobsets may import from derivations. Off unless asked for,
    /// because it lets an evaluation demand builds.
    #[serde(default)]
    allow_import_from_derivation: bool,

    /// How many `nix-eval-jobs` workers to run.
    #[serde(default = "default_workers")]
    evaluator_workers: u64,

    /// The memory each of them may use, in MiB, before it is restarted.
    #[serde(default = "default_max_memory_size")]
    evaluator_max_memory_size: u64,

    /// How many jobsets to evaluate at once.
    #[serde(default = "default_max_concurrent_evals")]
    max_concurrent_evals: u64,

    /// Where to fetch a build's output from when a `build` or `sysbuild`
    /// input names one this machine does not have. Unset means the store is
    /// expected to have everything already.
    #[serde(default)]
    eval_substituter: Option<String>,
}

fn default_workers() -> u64 {
    1
}

fn default_max_memory_size() -> u64 {
    4096
}

fn default_max_concurrent_evals() -> u64 {
    4
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
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                tracing::info!("no configuration at {path}, using defaults");
                return Ok(Self::default());
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

    pub(crate) fn evaluator_workers(&self) -> u64 {
        self.evaluator_workers
    }

    pub(crate) fn evaluator_max_memory_size(&self) -> u64 {
        self.evaluator_max_memory_size
    }

    pub(crate) fn eval_substituter(&self) -> Option<&str> {
        self.eval_substituter.as_deref()
    }

    /// At least one, so that a configuration of zero does not stop the
    /// evaluator rather than slowing it down.
    pub(crate) fn max_concurrent_evals(&self) -> usize {
        usize::try_from(self.max_concurrent_evals.max(1)).unwrap_or(usize::MAX)
    }
}

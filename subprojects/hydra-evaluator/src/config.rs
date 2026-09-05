//! What the evaluator is configured with.
//!
//! Its own file, as the queue runner and the builder have theirs. The
//! settings here used to be read from `hydra.conf` by `hydra-eval-jobset`;
//! nothing else reads them, and `Hydra::Config` warns about any left there.

#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
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
pub struct HydraConfig {
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

fn default_system_features() -> String {
    "recursive-nix".to_owned()
}

impl HydraConfig {
    /// Read the file, or take the defaults if it is not there.
    ///
    /// Absent is fine -- every setting has a default -- but present and
    /// unreadable is not, since that is a configuration someone wrote and
    /// expects to be in effect.
    pub fn load(path: &str) -> Result<Self, ConfigError> {
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

    pub fn allow_import_from_derivation(&self) -> bool {
        self.allow_import_from_derivation
    }

    pub fn evaluator_workers(&self) -> u64 {
        self.evaluator_workers
    }

    pub fn evaluator_max_memory_size(&self) -> u64 {
        self.evaluator_max_memory_size
    }

    pub fn evaluation_build_system_features(&self) -> &str {
        &self.evaluation_build_system_features
    }

    pub fn evaluation_build_store_uri(&self) -> Option<&str> {
        self.evaluation_build_store_uri.as_deref()
    }

    pub fn eval_substituter(&self) -> Option<&str> {
        self.eval_substituter.as_deref()
    }
}

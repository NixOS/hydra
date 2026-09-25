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
    /// How many jobsets to evaluate at once.
    #[serde(default = "default_max_concurrent_evals")]
    max_concurrent_evals: u64,
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

    /// At least one, so that a configuration of zero slows the evaluator down
    /// rather than stopping it.
    pub(crate) fn max_concurrent_evals(&self) -> usize {
        usize::try_from(self.max_concurrent_evals.max(1)).unwrap_or(usize::MAX)
    }
}

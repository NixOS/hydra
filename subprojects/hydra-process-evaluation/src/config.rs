//! The one setting processing needs, read from `hydra-submit-evaluation`'s
//! configuration file.
//!
//! That file is the evaluator's, and says where evaluated derivations are
//! rooted; rooting them happens here, once they are known. Everything else
//! in it is submission's business, so unknown keys are expected and ignored.

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
pub(crate) struct Config {
    /// Where to root the evaluated derivations. This must be the
    /// `gc_roots_dir` of `hydra.conf`, which `hydra-update-gc-roots` tidies.
    /// Unset means `<state dir>/gcroots/per-user/$LOGNAME/hydra-roots`, as for
    /// the queue runner.
    #[serde(default)]
    roots_dir: Option<std::path::PathBuf>,
}

impl Config {
    /// Read the file, or take the defaults if it is not there.
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

    pub(crate) fn roots_dir(&self) -> Option<&std::path::Path> {
        self.roots_dir.as_deref()
    }
}

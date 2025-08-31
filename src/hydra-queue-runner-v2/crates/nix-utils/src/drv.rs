use ahash::AHashMap;
use tokio::io::{AsyncBufReadExt as _, BufReader};
use tokio_stream::wrappers::LinesStream;

use crate::StorePath;

#[derive(Debug, Clone)]
pub struct Output {
    pub name: String,
    pub path: Option<StorePath>,
    pub hash: Option<String>,
    pub hash_algo: Option<String>,
}

#[derive(Debug, Clone)]
pub struct DerivationEnv {
    inner: AHashMap<String, String>,
}

impl DerivationEnv {
    fn new(v: AHashMap<String, String>) -> Self {
        Self { inner: v }
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.inner.get(k).map(|v| v.as_str())
    }

    pub fn get_required_system_features(&self) -> Vec<&str> {
        self.inner
            .get("requiredSystemFeatures")
            .map(|v| v.as_str())
            .unwrap_or_default()
            .split(' ')
            .filter(|v| !v.is_empty())
            .collect()
    }

    pub fn get_output_hash(&self) -> Option<&str> {
        self.inner.get("outputHash").map(|v| v.as_str())
    }

    pub fn get_output_hash_mode(&self) -> Option<&str> {
        self.inner.get("outputHash").map(|v| v.as_str())
    }
}

#[derive(Debug, Clone)]
pub struct Derivation {
    pub env: DerivationEnv,
    pub input_drvs: Vec<String>,
    pub outputs: Vec<Output>,
    pub name: String,
    pub system: String,
}

impl Derivation {
    fn new(path: String, v: nix_diff::types::Derivation) -> Result<Self, std::str::Utf8Error> {
        Ok(Self {
            env: DerivationEnv::new(
                v.env
                    .into_iter()
                    .filter_map(|(k, v)| {
                        Some((String::from_utf8(k).ok()?, String::from_utf8(v).ok()?))
                    })
                    .collect(),
            ),
            input_drvs: v
                .input_derivations
                .into_keys()
                .filter_map(|v| String::from_utf8(v).ok())
                .collect(),
            outputs: v
                .outputs
                .into_iter()
                .filter_map(|(k, v)| {
                    Some(Output {
                        name: String::from_utf8(k).ok()?,
                        path: if v.path.is_empty() {
                            None
                        } else {
                            String::from_utf8(v.path).ok().map(|p| StorePath::new(&p))
                        },
                        hash: v.hash.map(String::from_utf8).transpose().ok()?,
                        hash_algo: v.hash_algorithm.map(String::from_utf8).transpose().ok()?,
                    })
                })
                .collect(),
            name: path,
            system: String::from_utf8(v.platform).unwrap_or_default(),
        })
    }
}

#[tracing::instrument(fields(%drv), err)]
pub async fn query_drv(drv: &StorePath) -> Result<Option<Derivation>, crate::Error> {
    if !drv.is_drv() {
        return Ok(None);
    }

    let full_path = drv.get_full_path();
    if !tokio::fs::try_exists(&full_path).await? {
        return Ok(None);
    }

    let input = tokio::fs::read_to_string(&full_path).await?;
    Ok(Some(Derivation::new(
        full_path,
        nix_diff::parser::parse_derivation_string(&input)?,
    )?))
}

#[derive(Debug, Clone)]
pub struct BuildOptions {
    max_log_size: u64,
    max_silent_time: i32,
    build_timeout: i32,
    substitute: bool,
    build: bool,
}

fn format_bool(v: bool) -> &'static str {
    if v { "true" } else { "false" }
}

impl BuildOptions {
    pub fn new(max_log_size: Option<u64>) -> Self {
        Self {
            max_log_size: max_log_size.unwrap_or(64u64 << 20),
            max_silent_time: 0,
            build_timeout: 0,
            substitute: false,
            build: true,
        }
    }

    pub fn complete(max_log_size: u64, max_silent_time: i32, build_timeout: i32) -> Self {
        Self {
            max_log_size,
            max_silent_time,
            build_timeout,
            substitute: false,
            build: true,
        }
    }

    pub fn substitute_only() -> Self {
        let mut o = Self::new(None);
        o.build = false;
        o.substitute = true;
        o.max_silent_time = 60 * 5;
        o.build_timeout = 60 * 5;
        o
    }

    pub fn set_max_silent_time(&mut self, max_silent_time: i32) {
        self.max_silent_time = max_silent_time;
    }

    pub fn set_build_timeout(&mut self, build_timeout: i32) {
        self.build_timeout = build_timeout;
    }

    pub fn get_max_log_size(&self) -> u64 {
        self.max_log_size
    }

    pub fn get_max_silent_time(&self) -> i32 {
        self.max_silent_time
    }

    pub fn get_build_timeout(&self) -> i32 {
        self.build_timeout
    }
}

#[allow(clippy::type_complexity)]
#[tracing::instrument(skip(opts, drvs), err)]
pub async fn realise_drvs(
    drvs: &[&StorePath],
    opts: &BuildOptions,
    kill_on_drop: bool,
) -> Result<
    (
        tokio::process::Child,
        tokio_stream::adapters::Merge<
            LinesStream<BufReader<tokio::process::ChildStdout>>,
            LinesStream<BufReader<tokio::process::ChildStderr>>,
        >,
    ),
    crate::Error,
> {
    use tokio_stream::StreamExt;

    let mut child = tokio::process::Command::new("nix-store")
        .args([
            "-r",
            "--quiet", // we want to always set this
            "--max-silent-time",
            &opts.max_silent_time.to_string(),
            "--timeout",
            &opts.build_timeout.to_string(),
            "--option",
            "max-build-log-size",
            &opts.max_log_size.to_string(),
            "--option",
            "fallback",
            format_bool(opts.build),
            "--option",
            "substitute",
            format_bool(opts.substitute),
            "--option",
            "builders",
            "",
        ])
        .args(drvs.iter().map(|v| v.get_full_path()))
        .kill_on_drop(kill_on_drop)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()?;

    let stdout = child.stdout.take().ok_or(crate::Error::Stream)?;
    let stderr = child.stderr.take().ok_or(crate::Error::Stream)?;

    let stdout = LinesStream::new(BufReader::new(stdout).lines());
    let stderr = LinesStream::new(BufReader::new(stderr).lines());

    Ok((child, StreamExt::merge(stdout, stderr)))
}

#[allow(clippy::type_complexity)]
#[tracing::instrument(skip(opts), fields(%drv), err)]
pub async fn realise_drv(
    drv: &StorePath,
    opts: &BuildOptions,
    kill_on_drop: bool,
) -> Result<
    (
        tokio::process::Child,
        tokio_stream::adapters::Merge<
            LinesStream<BufReader<tokio::process::ChildStdout>>,
            LinesStream<BufReader<tokio::process::ChildStderr>>,
        >,
    ),
    crate::Error,
> {
    realise_drvs(&[drv], opts, kill_on_drop).await
}

#[tracing::instrument(skip(outputs))]
pub async fn query_missing_outputs(outputs: Vec<Output>) -> Vec<Output> {
    use futures::stream::StreamExt as _;

    tokio_stream::iter(outputs)
        .map(|o| async move {
            let Some(path) = &o.path else {
                return None;
            };
            if !super::check_if_storepath_exists(path).await {
                Some(o)
            } else {
                None
            }
        })
        .buffered(50)
        .filter_map(|o| async { o })
        .collect()
        .await
}

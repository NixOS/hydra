//! Fetching jobset inputs whose type comes from a Perl plugin.
//!
//! Input types are a plugin interface and the plugins are Perl, so those
//! types are resolved by `hydra-fetch-input` rather than here. Everything
//! else about an evaluation is ours; this is the one thing we ask for.
//!
//! One worker serves a whole evaluation. Starting it costs a second or two --
//! it loads the schema and instantiates every plugin -- which is worth paying
//! once and not once per input.

use std::process::Stdio;

use color_eyre::eyre::{self, WrapErr as _};
use tokio::io::{AsyncBufReadExt as _, AsyncWriteExt as _, BufReader, Lines};
use tokio::process::{Child, ChildStdin};

use crate::inputs::JobsetInput;

/// What we ask the worker for: one input, by type and value.
#[derive(Debug, serde::Serialize)]
struct Request<'a> {
    r#type: &'a str,
    name: &'a str,
    value: Option<&'a str>,
    project: &'a str,
    jobset: &'a str,
}

/// What it answers with: the input's alternatives, or why it could not.
#[derive(Debug, serde::Deserialize)]
struct Reply {
    #[serde(default)]
    inputs: Option<Vec<JobsetInput>>,
    #[serde(default)]
    error: Option<String>,
}

/// A running `hydra-fetch-input`.
#[derive(Debug)]
pub(crate) struct InputFetcher {
    child: Child,
    stdin: ChildStdin,
    stdout: Lines<BufReader<tokio::process::ChildStdout>>,
}

impl InputFetcher {
    pub(crate) fn start() -> eyre::Result<Self> {
        // stderr is inherited on purpose: the worker's diagnostics, and
        // anything a plugin prints, belong in our log.
        let mut child = tokio::process::Command::new("hydra-fetch-input")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .wrap_err("failed to start hydra-fetch-input")?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| eyre::eyre!("hydra-fetch-input has no stdin"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| eyre::eyre!("hydra-fetch-input has no stdout"))?;

        Ok(Self {
            child,
            stdin,
            stdout: BufReader::new(stdout).lines(),
        })
    }

    /// Resolve one input of a plugin-provided type.
    ///
    /// An input that fails to fetch is an error for that input alone; the
    /// worker stays up and the caller may ask for the next one.
    pub(crate) async fn fetch(
        &mut self,
        r#type: &str,
        name: &str,
        value: Option<&str>,
        project: &str,
        jobset: &str,
    ) -> eyre::Result<Vec<JobsetInput>> {
        let request = serde_json::to_string(&Request {
            r#type,
            name,
            value,
            project,
            jobset,
        })
        .wrap_err("failed to encode an input request")?;

        self.stdin
            .write_all(format!("{request}\n").as_bytes())
            .await
            .wrap_err("failed to send an input request")?;
        self.stdin.flush().await?;

        let line = self
            .stdout
            .next_line()
            .await
            .wrap_err("failed to read the reply")?
            .ok_or_else(|| eyre::eyre!("hydra-fetch-input exited while fetching `{name}`"))?;

        let reply: Reply = serde_json::from_str(&line)
            .wrap_err_with(|| format!("hydra-fetch-input sent an unreadable reply: {line}"))?;

        match (reply.inputs, reply.error) {
            (Some(inputs), _) => Ok(inputs),
            (None, Some(error)) => Err(eyre::eyre!("{error}")),
            (None, None) => Err(eyre::eyre!(
                "hydra-fetch-input replied with neither inputs nor an error"
            )),
        }
    }

    /// Close the pipe and wait, so the worker is not left behind.
    pub(crate) async fn shutdown(mut self) {
        drop(self.stdin);
        if let Err(e) = self.child.wait().await {
            tracing::warn!("hydra-fetch-input did not exit cleanly: {e}");
        }
    }
}

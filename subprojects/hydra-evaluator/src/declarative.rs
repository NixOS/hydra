//! Declarative projects: preparing the `.jobsets` jobset for evaluation.
//!
//! A declarative project's jobsets come from a specification file in one of
//! its inputs. That file may name the jobsets outright, in which case they
//! are created from it and there is nothing to evaluate; or it may describe
//! how to generate them, in which case it reconfigures `.jobsets` and
//! supplies the inputs its expression is evaluated with. Either way the work
//! is writing jobset rows from a specification, which the Perl helpers do,
//! so `hydra-prepare-declarative-jobset` does it and reports back.

use std::collections::BTreeMap;

use color_eyre::eyre::{self, WrapErr as _};

use crate::inputs::{InputInfo, JobsetInput};

/// What the specification turned out to be.
#[derive(Debug)]
pub(crate) enum Prepared {
    /// The jobsets were named outright and have been created.
    Declared,
    /// `.jobsets` has been reconfigured, and evaluates with these inputs in
    /// addition to its own.
    Generated { inputs: InputInfo },
}

#[derive(Debug, serde::Deserialize)]
struct Reply {
    #[serde(default)]
    declared: bool,
    #[serde(default)]
    inputs: BTreeMap<String, Vec<JobsetInput>>,
    #[serde(default)]
    error: Option<String>,
}

pub(crate) async fn prepare(project: &str) -> eyre::Result<Prepared> {
    let out = tokio::process::Command::new("hydra-prepare-declarative-jobset")
        .arg(project)
        .output()
        .await
        .wrap_err("failed to run hydra-prepare-declarative-jobset")?;
    if !out.status.success() {
        let stderr = String::from_utf8(out.stderr)
            .wrap_err("hydra-prepare-declarative-jobset failed, with non-UTF-8 output")?;
        eyre::bail!("hydra-prepare-declarative-jobset failed:\n{stderr}");
    }

    let reply: Reply = serde_json::from_slice(&out.stdout)
        .wrap_err("hydra-prepare-declarative-jobset sent an unreadable reply")?;
    if let Some(error) = reply.error {
        eyre::bail!("{error}");
    }
    Ok(if reply.declared {
        Prepared::Declared
    } else {
        Prepared::Generated {
            inputs: reply.inputs,
        }
    })
}

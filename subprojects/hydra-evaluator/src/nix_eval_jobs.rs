//! Running `nix-eval-jobs` over a jobset's resolved inputs.
//!
//! The arguments describe the evaluation, so they are built separately from
//! running it.

use std::collections::BTreeMap;
use std::fmt::Write as _;
use std::process::Stdio;

use color_eyre::eyre::{self, WrapErr as _};
use db::StoreDir;
use sha2::{Digest as _, Sha256};
use tokio::io::{AsyncBufReadExt as _, BufReader};

use crate::config::HydraConfig;
use crate::inputs::{InputInfo, JobsetInput};

/// What a jobset says to evaluate.
#[derive(Debug)]
pub(crate) struct Expression<'a> {
    /// The flake reference, when the jobset is a flake.
    pub flake: Option<&'a str>,
    /// Otherwise, the input holding the expression and the path within it.
    pub nix_expr_input: Option<&'a str>,
    pub nix_expr_path: Option<&'a str>,
}

/// One job, as `nix-eval-jobs` reports it.
///
/// Deliberately loose: the shape of this is `nix-eval-jobs`' to define, and
/// a field we do not know about is not our business to reject.
#[derive(Debug, serde::Deserialize)]
pub(crate) struct Job {
    #[serde(default)]
    pub attr: String,
    /// The derivation's name, which is not in `meta`.
    pub name: Option<String>,
    pub error: Option<String>,
    #[serde(rename = "drvPath")]
    pub drv_path: Option<String>,
    /// Output name to path; a content-addressed output has no path until it
    /// is built.
    #[serde(default)]
    pub outputs: BTreeMap<String, Option<String>>,
    pub system: Option<String>,
    pub constituents: Option<Vec<String>>,
    #[serde(default)]
    pub meta: Meta,
}

/// The parts of a job's `meta` that Hydra records.
///
/// Only these are kept: on nixpkgs the rest of `meta` -- maintainers' details,
/// platforms, long descriptions -- would cost a lot of memory for nothing.
///
/// All optional: a jobset may set none of them, and a missing or empty value
/// means "not stated" rather than "empty string". Read leniently: an
/// unexpected type, of a value or of `meta` itself, never makes the job
/// unreadable.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Meta {
    pub name: Option<String>,
    pub description: Option<String>,
    pub license: Option<String>,
    pub homepage: Option<String>,
    pub maintainers: Option<String>,
    pub max_silent: Option<i32>,
    pub timeout: Option<i32>,
    pub priority: i32,
    pub is_channel: i32,
}

/// The keys of `meta` that [`Meta`] reads, as given.
#[derive(Default)]
struct RawMeta {
    name: Option<serde_json::Value>,
    description: Option<serde_json::Value>,
    license: Option<serde_json::Value>,
    homepage: Option<serde_json::Value>,
    maintainers: Option<serde_json::Value>,
    max_silent: Option<serde_json::Value>,
    timeout: Option<serde_json::Value>,
    scheduling_priority: Option<serde_json::Value>,
    is_channel: Option<serde_json::Value>,
}

#[derive(serde::Deserialize)]
#[serde(field_identifier, rename_all = "camelCase")]
enum MetaKey {
    Name,
    Description,
    License,
    Homepage,
    Maintainers,
    MaxSilent,
    Timeout,
    SchedulingPriority,
    IsChannel,
    #[serde(other)]
    Other,
}

impl Default for Meta {
    fn default() -> Self {
        RawMeta::default().into()
    }
}

impl<'de> serde::Deserialize<'de> for Meta {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        d.deserialize_any(MetaVisitor)
    }
}

/// Reads the known keys of an object and skips the rest without buffering
/// them. Anything but an object reads as no meta, as Hydra always did.
struct MetaVisitor;

impl<'de> serde::de::Visitor<'de> for MetaVisitor {
    type Value = Meta;

    fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("any JSON value")
    }

    fn visit_map<A: serde::de::MapAccess<'de>>(self, mut map: A) -> Result<Meta, A::Error> {
        let mut raw = RawMeta::default();
        while let Some(key) = map.next_key()? {
            let slot = match key {
                MetaKey::Name => &mut raw.name,
                MetaKey::Description => &mut raw.description,
                MetaKey::License => &mut raw.license,
                MetaKey::Homepage => &mut raw.homepage,
                MetaKey::Maintainers => &mut raw.maintainers,
                MetaKey::MaxSilent => &mut raw.max_silent,
                MetaKey::Timeout => &mut raw.timeout,
                MetaKey::SchedulingPriority => &mut raw.scheduling_priority,
                MetaKey::IsChannel => &mut raw.is_channel,
                MetaKey::Other => {
                    map.next_value::<serde::de::IgnoredAny>()?;
                    continue;
                }
            };
            // A repeated key keeps its last value, as serde_json's maps do.
            *slot = map.next_value()?;
        }
        Ok(raw.into())
    }

    fn visit_seq<A: serde::de::SeqAccess<'de>>(self, mut seq: A) -> Result<Meta, A::Error> {
        while seq.next_element::<serde::de::IgnoredAny>()?.is_some() {}
        Ok(Meta::default())
    }

    fn visit_unit<E>(self) -> Result<Meta, E> {
        Ok(Meta::default())
    }

    fn visit_bool<E>(self, _: bool) -> Result<Meta, E> {
        Ok(Meta::default())
    }

    fn visit_i64<E>(self, _: i64) -> Result<Meta, E> {
        Ok(Meta::default())
    }

    fn visit_u64<E>(self, _: u64) -> Result<Meta, E> {
        Ok(Meta::default())
    }

    fn visit_f64<E>(self, _: f64) -> Result<Meta, E> {
        Ok(Meta::default())
    }

    fn visit_str<E>(self, _: &str) -> Result<Meta, E> {
        Ok(Meta::default())
    }
}

impl From<RawMeta> for Meta {
    fn from(raw: RawMeta) -> Self {
        Self {
            name: nonempty_string(raw.name),
            description: nonempty_string(raw.description),
            // `license` and `maintainers` are lists of attribute sets in
            // nixpkgs and bare strings elsewhere, so both are flattened to a
            // comma-separated list of one field.
            license: concat_strings(raw.license.as_ref(), "shortName"),
            homepage: nonempty_string(raw.homepage),
            maintainers: concat_strings(raw.maintainers.as_ref(), "email"),
            max_silent: raw.max_silent.as_ref().and_then(as_int),
            timeout: raw.timeout.as_ref().and_then(as_int),
            priority: raw
                .scheduling_priority
                .as_ref()
                .and_then(as_int)
                .unwrap_or(100),
            is_channel: i32::from(
                raw.is_channel
                    .as_ref()
                    .and_then(serde_json::Value::as_bool)
                    .unwrap_or(false),
            ),
        }
    }
}

fn nonempty_string(v: Option<serde_json::Value>) -> Option<String> {
    match v {
        Some(serde_json::Value::String(s)) if !s.is_empty() => Some(s),
        _ => None,
    }
}

fn as_int(v: &serde_json::Value) -> Option<i32> {
    v.as_i64().and_then(|n| i32::try_from(n).ok())
}

/// Flatten a `meta` value that may be a string, a list, or a list of
/// attribute sets, taking `key` from each set.
fn concat_strings(value: Option<&serde_json::Value>, key: &str) -> Option<String> {
    let mut out = Vec::new();
    collect_strings(value, key, &mut out);
    if out.is_empty() {
        None
    } else {
        Some(out.join(", "))
    }
}

fn collect_strings(value: Option<&serde_json::Value>, key: &str, out: &mut Vec<String>) {
    match value {
        Some(serde_json::Value::Object(map)) => {
            if let Some(v) = map.get(key).and_then(serde_json::Value::as_str) {
                out.push(v.to_owned());
            }
        }
        Some(serde_json::Value::Array(items)) => {
            for item in items {
                collect_strings(Some(item), key, out);
            }
        }
        Some(serde_json::Value::String(s)) => out.push(s.clone()),
        Some(v) if !v.is_null() => out.push(v.to_string()),
        _ => {}
    }
}

/// Assemble the `nix-eval-jobs` command line for a jobset.
pub(crate) fn command(
    store_dir: &StoreDir,
    config: &HydraConfig,
    inputs: &InputInfo,
    expr: &Expression<'_>,
) -> eyre::Result<Vec<String>> {
    let mut cmd: Vec<String> = Vec::new();

    if let Some(flake) = expr.flake {
        // The eval cache is off deliberately: Hydra evaluates a given
        // revision about once, so parallel workers would contend for the
        // SQLite lock and get nothing back for it.
        cmd.extend(
            [
                "--option",
                "eval-cache",
                "false",
                "--flake",
                flake,
                "--select",
                "flake: flake.outputs.hydraJobs or flake.outputs.checks or (throw \"flake does not provide any Hydra jobs or checks\")",
            ]
            .map(str::to_owned),
        );
    } else {
        let input_name = expr
            .nix_expr_input
            .ok_or_else(|| eyre::eyre!("the jobset has neither a flake nor an expression"))?;
        let path = expr.nix_expr_path.unwrap_or_default();
        eyre::ensure!(
            inputs.contains_key(input_name),
            "cannot find the input containing the job expression"
        );

        let restrict_eval = if config.allow_unrestricted_eval() {
            "false"
        } else {
            "true"
        };
        cmd.extend(["--option", "restrict-eval", restrict_eval].map(str::to_owned));
        cmd.push(format!("<{input_name}/{path}>"));
        cmd.extend(inputs_to_args(store_dir, inputs)?);
    }

    cmd.extend([
        "--max-jobs".to_owned(),
        config.evaluator_max_jobs().to_string(),
    ]);
    cmd.push("--meta".to_owned());
    cmd.push("--constituents".to_owned());
    cmd.push("--force-recurse".to_owned());
    if !config.allow_import_from_derivation() {
        cmd.extend(["--option", "allow-import-from-derivation", "false"].map(str::to_owned));
    }
    cmd.extend([
        "--workers".to_owned(),
        config.evaluator_workers().to_string(),
    ]);
    cmd.extend([
        "--max-memory-size".to_owned(),
        config.evaluator_max_memory_size().to_string(),
    ]);

    Ok(cmd)
}

/// The hash that decides whether these inputs were evaluated before. It
/// covers the expression and the input arguments and is computed exactly as
/// the Perl did, so evaluations the Perl recorded still count. Flakes are
/// compared separately, by their locked reference.
pub(crate) fn input_hash(
    store_dir: &StoreDir,
    inputs: &InputInfo,
    expr: &Expression<'_>,
) -> eyre::Result<String> {
    let mut args = vec![
        expr.nix_expr_input.unwrap_or_default().to_owned(),
        expr.nix_expr_path.unwrap_or_default().to_owned(),
    ];
    args.extend(inputs_to_args(store_dir, inputs)?);
    Ok(hex::encode(Sha256::digest(args.join(" ").as_bytes())))
}

/// Turn the resolved inputs into the arguments that make them visible to the
/// expression.
fn inputs_to_args(store_dir: &StoreDir, inputs: &InputInfo) -> eyre::Result<Vec<String>> {
    let mut args = Vec::new();

    for (name, alts) in inputs {
        // A `build` input whose job has never been built resolves to
        // nothing, and the expression is left to default it.
        let [alt] = alts.as_slice() else {
            eyre::ensure!(
                alts.is_empty(),
                "multiple jobset input alternatives are no longer supported"
            );
            continue;
        };

        if let Some(path) = &alt.store_path {
            args.extend(["-I".to_owned(), format!("{name}={}", full(store_dir, path))]);
        }

        match alt.r#type.as_deref().unwrap_or_default() {
            "string" => args.extend([
                "--argstr".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "boolean" | "nix" => args.extend([
                "--arg".to_owned(),
                name.clone(),
                alt.value.clone().unwrap_or_default(),
            ]),
            "eval" => {
                let mut s = String::from("{ ");
                for (job, path) in alt.jobs.iter().flatten() {
                    let _ = write!(s, "{job} = builtins.storePath {}; ", full(store_dir, path));
                }
                s.push('}');
                args.extend(["--arg".to_owned(), name.clone(), s]);
            }
            _ => args.extend([
                "--arg".to_owned(),
                name.clone(),
                build_input_to_string(store_dir, alt),
            ]),
        }
    }

    Ok(args)
}

/// Describe a fetched input to the expression.
///
/// The attribute names here are a jobset-visible interface -- expressions
/// read `rev`, `revCount`, `shortRev` and the rest -- so they are not ours
/// to rename.
fn build_input_to_string(store_dir: &StoreDir, input: &JobsetInput) -> String {
    let mut s = String::from("{ outPath = builtins.storePath ");
    s.push_str(&full(store_dir, input.store_path.as_deref().unwrap_or("")));
    let _ = write!(
        s,
        "; inputType = \"{}\"",
        input.r#type.as_deref().unwrap_or("")
    );

    // In the Perl's order, which the input hash depends on.
    let quoted = |s: &mut String, key: &str, value: &Option<String>| {
        if let Some(v) = value {
            let _ = write!(s, "; {key} = \"{v}\"");
        }
    };
    quoted(&mut s, "uri", &input.uri);
    if let Some(n) = input.rev_number {
        let _ = write!(s, "; rev = {n}");
    }
    quoted(&mut s, "rev", &input.revision);
    if let Some(n) = input.rev_count {
        let _ = write!(s, "; revCount = {n}");
    }
    quoted(&mut s, "gitTag", &input.git_tag);
    quoted(&mut s, "shortRev", &input.short_rev);
    quoted(&mut s, "version", &input.version);
    quoted(&mut s, "outputName", &input.output_name);
    if let Some(drv) = &input.drv_path {
        let _ = write!(s, "; drvPath = builtins.storePath {}", full(store_dir, drv));
    }

    s.push_str(";}");
    s
}

/// A store path as a full path, which is what Nix takes -- `builtins.storePath`,
/// `-I`, `nix copy`. Hydra keeps store paths as bare names, mostly.
pub(crate) fn full(store_dir: &StoreDir, path: &str) -> String {
    if path.starts_with('/') {
        path.to_owned()
    } else {
        format!("{store_dir}/{path}")
    }
}

/// Run `nix-eval-jobs` and hand back the jobs it reports.
///
/// It roots each derivation in `gc_roots_dir` as it goes, so the garbage
/// collector cannot delete one before the builds that need it are queued.
///
/// Its stderr is logged at debug, and its tail ends up in the error if it
/// fails, so the jobset shows why.
pub(crate) async fn run(
    program: &crate::programs::NixEvalJobsPath,
    cmd: &[String],
    gc_roots_dir: &std::path::Path,
) -> eyre::Result<Vec<Job>> {
    // NIX_PATH is cleared so that an evaluation depends on its declared
    // inputs and nothing about the machine it runs on.
    let mut child = tokio::process::Command::new(program)
        .args(cmd)
        .arg("--gc-roots-dir")
        .arg(gc_roots_dir)
        .env_remove("NIX_PATH")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .wrap_err("failed to start nix-eval-jobs")?;

    let stderr_tail = crate::forward_stderr("nix-eval-jobs", &mut child)?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| eyre::eyre!("nix-eval-jobs has no stdout"))?;
    let mut lines = BufReader::new(stdout).lines();

    let mut jobs = Vec::new();
    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Job>(&line) {
            Ok(job) => jobs.push(job),
            // A line we cannot read is worth complaining about but not worth
            // abandoning the evaluation over, which is what the Perl did.
            Err(e) => tracing::warn!("nix-eval-jobs sent unreadable JSON: {e}: {line}"),
        }
    }

    let status = child.wait().await?;
    if !status.success() {
        let tail = stderr_tail.await.unwrap_or_default();
        if tail.is_empty() {
            eyre::bail!("nix-eval-jobs failed: {status}");
        }
        eyre::bail!("nix-eval-jobs failed: {status}\n{tail}");
    }

    Ok(jobs)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn meta(json: &str) -> Meta {
        serde_json::from_str::<Job>(&format!(r#"{{"attr":"a","meta":{json}}}"#))
            .unwrap()
            .meta
    }

    #[test]
    fn meta_missing_null_or_empty_is_the_default() {
        let missing = serde_json::from_str::<Job>(r#"{"attr":"a"}"#).unwrap().meta;
        assert_eq!(missing, meta("null"));
        assert_eq!(missing, meta("{}"));
        assert_eq!(
            missing,
            Meta {
                name: None,
                description: None,
                license: None,
                homepage: None,
                maintainers: None,
                max_silent: None,
                timeout: None,
                priority: 100,
                is_channel: 0,
            }
        );
    }

    #[test]
    fn meta_keeps_what_hydra_records() {
        let m = meta(
            r#"{"name":"hello-2.12","description":"Hi","homepage":"https://x",
                "maxSilent":60,"timeout":3600,"schedulingPriority":5,"isChannel":true,
                "platforms":["x86_64-linux"],"longDescription":"ignored"}"#,
        );
        assert_eq!(m.name.as_deref(), Some("hello-2.12"));
        assert_eq!(m.description.as_deref(), Some("Hi"));
        assert_eq!(m.homepage.as_deref(), Some("https://x"));
        assert_eq!((m.max_silent, m.timeout), (Some(60), Some(3600)));
        assert_eq!((m.priority, m.is_channel), (5, 1));
    }

    #[test]
    fn meta_of_the_wrong_type_reads_as_missing() {
        let m = meta(
            r#"{"name":"","description":1,"homepage":null,"maxSilent":4294967296,
                "timeout":1.5,"schedulingPriority":"high","isChannel":"yes"}"#,
        );
        assert_eq!(m, meta("{}"));
    }

    #[test]
    fn meta_of_any_shape_is_readable() {
        for json in [r#""x""#, "1", "-1", "1.5", "true", r#"["a",{"name":"x"}]"#] {
            assert_eq!(meta(json), meta("{}"), "{json}");
        }
        // A repeated key keeps its last value.
        let m = meta(r#"{"name":"a","platforms":[],"name":"b","platforms":{}}"#);
        assert_eq!(m.name.as_deref(), Some("b"));
    }

    #[test]
    fn meta_license_and_maintainers_are_flattened() {
        let license = |json| meta(&format!(r#"{{"license":{json}}}"#)).license;
        assert_eq!(license(r#""mit""#).as_deref(), Some("mit"));
        assert_eq!(license(r#"{"shortName":"mit"}"#).as_deref(), Some("mit"));
        assert_eq!(
            license(r#"[{"shortName":"mit","free":true},"bsd3",{"spdxId":"x"},null,2,[{"shortName":"gpl"}]]"#)
                .as_deref(),
            Some("mit, bsd3, 2, gpl")
        );
        assert_eq!(license("true").as_deref(), Some("true"));
        assert_eq!(license("[]"), None);
        assert_eq!(license(r#"{"spdxId":"x"}"#), None);

        let m = meta(r#"{"maintainers":[{"email":"a@x","github":"a"},{"email":"b@x"}]}"#);
        assert_eq!(m.maintainers.as_deref(), Some("a@x, b@x"));
    }
}

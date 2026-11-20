//! What `nix-eval-jobs` wrote, read back from the evaluation build's output.

use std::collections::BTreeMap;

use color_eyre::eyre::{self, WrapErr as _};

/// One job, as `nix-eval-jobs` reports it.
///
/// Deliberately loose: the shape of this is `nix-eval-jobs`' to define, and
/// a field we do not know about is not our business to reject.
#[derive(Debug, serde::Deserialize)]
pub(crate) struct Job {
    #[serde(default)]
    pub(crate) attr: String,
    /// The derivation's name, which is not in `meta`.
    pub(crate) name: Option<String>,
    pub(crate) error: Option<String>,
    #[serde(rename = "drvPath")]
    pub(crate) drv_path: Option<String>,
    /// Output name to path; a content-addressed output has no path until it
    /// is built.
    #[serde(default)]
    pub(crate) outputs: BTreeMap<String, Option<String>>,
    pub(crate) system: Option<String>,
    pub(crate) constituents: Option<Vec<String>>,
    #[serde(default)]
    pub(crate) meta: Meta,
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
    pub(crate) name: Option<String>,
    pub(crate) description: Option<String>,
    pub(crate) license: Option<String>,
    pub(crate) homepage: Option<String>,
    pub(crate) maintainers: Option<String>,
    pub(crate) max_silent: Option<i32>,
    pub(crate) timeout: Option<i32>,
    pub(crate) priority: i32,
    pub(crate) is_channel: i32,
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

/// Read the jobs out of a finished evaluation build's output.
pub(crate) fn read(path: &str) -> eyre::Result<Vec<Job>> {
    let contents = fs_err::read_to_string(path)
        .wrap_err_with(|| format!("could not read the evaluation's output at `{path}'"))?;

    let mut jobs = Vec::new();
    for line in contents.lines() {
        if line.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<Job>(line) {
            Ok(job) => jobs.push(job),
            // A line we cannot read is worth complaining about but not worth
            // abandoning the evaluation over.
            Err(e) => tracing::warn!("nix-eval-jobs wrote unreadable JSON: {e}: {line}"),
        }
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

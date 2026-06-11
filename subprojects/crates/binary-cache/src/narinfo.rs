use std::collections::BTreeSet;

use harmonia_store_nar_info::UnkeyedNarInfo;
use harmonia_store_path::{ParseStorePathError, StoreDir, StorePath};
use harmonia_store_path_info::fingerprint_path;
use harmonia_store_path_info::{NarHash, UnkeyedValidPathInfo};
use harmonia_utils_hash::Hash;
use harmonia_utils_hash::HashFormat as _;
use harmonia_utils_signature::{SecretKey, Signature};
use secrecy::ExposeSecret as _;

use crate::Compression;

pub use harmonia_store_nar_info::NarInfo;

/// Re-export the harmonia narinfo formatter.
pub use harmonia_store_nar_info::format_narinfo_txt;

/// Parse a hash string (in any format: hex, nix32, sri) into a typed `Hash`.
pub fn parse_hash(raw: &str) -> Option<Hash> {
    raw.parse::<harmonia_utils_hash::fmt::Any<Hash>>()
        .map(harmonia_utils_hash::fmt::Any::into_hash)
        .ok()
}

/// Parse a hash string into a `NarHash` (SHA256 only).
#[must_use]
pub fn parse_nar_hash(raw: &str) -> Option<NarHash> {
    parse_hash(raw).and_then(|h| NarHash::try_from(h).ok())
}

/// Build a `NarInfo` from a `PathInfo` (`UnkeyedValidPathInfo`), optionally signing it.
#[must_use]
pub fn narinfo_from_path_info(
    path: &StorePath,
    path_info: UnkeyedValidPathInfo,
    compression: Compression,
    store_dir: &StoreDir,
    signing_keys: &[secrecy::SecretString],
) -> NarInfo {
    let nar_hash_url = {
        let h: Hash = path_info.nar_hash.into();
        format!("{:#}", h.as_base32())
    };

    let original_signatures = path_info.signatures.clone();
    let url = format!("nar/{}.{}", nar_hash_url, compression.ext());

    let mut narinfo = NarInfo {
        path: path.clone(),
        info: UnkeyedNarInfo {
            info: path_info,
            url: Some(url),
            compression: Some(compression.as_str().to_owned()),
            download_hash: None,
            download_size: None,
        },
    };

    // Sign with the provided signing keys (clears existing sigs first)
    narinfo = clear_sigs_and_sign(narinfo, store_dir, signing_keys);

    // If signing produced no sigs but path_info had sigs, restore them
    if narinfo.info.info.signatures.is_empty() && !original_signatures.is_empty() {
        narinfo.info.info.signatures = original_signatures;
    }

    narinfo
}

/// Build a simple `NarInfo` without signing.
#[must_use]
pub fn narinfo_simple(
    path: &StorePath,
    path_info: UnkeyedValidPathInfo,
    compression: Compression,
) -> NarInfo {
    let nar_hash_url = {
        let h: Hash = path_info.nar_hash.into();
        format!("{:#}", h.as_base32())
    };

    NarInfo {
        path: path.clone(),
        info: UnkeyedNarInfo {
            info: path_info,
            url: Some(format!("nar/{}.{}", nar_hash_url, compression.ext())),
            compression: Some(compression.as_str().to_owned()),
            download_hash: None,
            download_size: None,
        },
    }
}

/// Clear signatures and re-sign with the provided signing keys.
#[must_use]
pub fn clear_sigs_and_sign(
    mut narinfo: NarInfo,
    store_dir: &StoreDir,
    signing_keys: &[secrecy::SecretString],
) -> NarInfo {
    narinfo.info.info.signatures.clear();
    if !signing_keys.is_empty() {
        let fp = fingerprint_path(
            store_dir,
            &narinfo.path,
            &narinfo.info.info.nar_hash,
            narinfo.info.info.nar_size,
            &narinfo.info.info.references,
        );
        for s in signing_keys {
            if let Ok(sk) = s.expose_secret().parse::<SecretKey>() {
                narinfo.info.info.signatures.insert(sk.sign(&fp));
            }
        }
    }
    narinfo
}

/// Return the `.ls` listing key for this narinfo.
#[must_use]
pub fn get_ls_path(narinfo: &NarInfo) -> String {
    format!("{}.ls", narinfo.path.hash())
}

#[derive(Debug, thiserror::Error)]
pub enum NarInfoError {
    #[error("missing required field: {0}")]
    MissingField(&'static str),
    #[error("invalid value for {field}: {value}")]
    InvalidValue {
        field: String,
        value: String,
        #[source]
        source: Box<dyn std::error::Error + Send + Sync>,
    },
    #[error("parse error on line {line}: {reason}")]
    Line { line: usize, reason: String },
    #[error("narinfo was not valid utf-8")]
    FromUtf8(#[from] std::str::Utf8Error),
}

/// Parse a narinfo text into a [`NarInfo`].
///
/// `FromStr` cannot be implemented directly on the re-exported type due to
/// Rust's orphan rules, so this free function is provided instead.
// TODO: harmonia should grow its own narinfo parser so we can use that instead
#[tracing::instrument(skip(raw), err)]
#[allow(clippy::too_many_lines)]
pub fn parse_narinfo(raw: &[u8]) -> Result<NarInfo, NarInfoError> {
    let input = str::from_utf8(raw)?;

    let mut store_path_opt: Option<StorePath> = None;
    let mut url_opt: Option<String> = None;
    let mut compression_opt: Option<String> = None;
    let mut file_hash: Option<Hash> = None;
    let mut file_size: Option<u64> = None;
    let mut nar_hash_opt: Option<NarHash> = None;
    let mut nar_size: u64 = 0;
    let mut have_nar_size = false;
    let mut references: BTreeSet<StorePath> = BTreeSet::new();
    let mut deriver: Option<StorePath> = None;
    let mut ca_str: Option<String> = None;
    let mut sigs: BTreeSet<Signature> = BTreeSet::new();

    for (idx, raw_line) in input.lines().enumerate() {
        let line_no = idx + 1;
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        let Some((k, v)) = line.split_once(':') else {
            return Err(NarInfoError::Line {
                line: line_no,
                reason: "expected `Key: value`".into(),
            });
        };
        let key = k.trim();
        let val = v
            .strip_prefix(' ')
            .map_or(v, |stripped| stripped)
            .trim_end();

        match key {
            "StorePath" => {
                // The field holds the full path, but `StorePath::from_str`
                // only accepts the base name. Parsing via the store
                // directory (assumed to be the default one throughout this
                // function) also rejects narinfos for a different store.
                store_path_opt = Some(StoreDir::default().parse(val).map_err(
                    |e: ParseStorePathError| NarInfoError::InvalidValue {
                        field: key.to_owned(),
                        value: val.to_owned(),
                        source: e.into(),
                    },
                )?);
            }
            "URL" => {
                url_opt = Some(val.to_string());
            }
            "Compression" => {
                compression_opt = Some(val.to_string());
            }
            "FileHash" => {
                file_hash = parse_hash(val);
            }
            "FileSize" => {
                file_size = Some(val.parse::<u64>().map_err(|e| NarInfoError::InvalidValue {
                    field: key.to_owned(),
                    value: val.to_owned(),
                    source: e.into(),
                })?);
            }
            "NarHash" => {
                nar_hash_opt = parse_nar_hash(val);
            }
            "NarSize" => {
                nar_size = val.parse::<u64>().map_err(|e| NarInfoError::InvalidValue {
                    field: key.to_owned(),
                    value: val.to_owned(),
                    source: e.into(),
                })?;
                have_nar_size = true;
            }
            "References" => {
                references = val
                    .split_whitespace()
                    .filter(|s| !s.is_empty())
                    .map(|s| {
                        s.parse()
                            .map_err(|e: ParseStorePathError| NarInfoError::InvalidValue {
                                field: key.to_owned(),
                                value: s.to_owned(),
                                source: e.into(),
                            })
                    })
                    .collect::<Result<_, _>>()?;
            }
            "Deriver" => {
                deriver = if val.is_empty() {
                    None
                } else {
                    Some(val.parse().map_err(|e: ParseStorePathError| {
                        NarInfoError::InvalidValue {
                            field: key.to_owned(),
                            value: val.to_owned(),
                            source: e.into(),
                        }
                    })?)
                };
            }
            "CA" => {
                ca_str = if val.is_empty() {
                    None
                } else {
                    Some(val.to_string())
                };
            }
            "Sig" => {
                if !val.is_empty()
                    && let Ok(sig) = val.parse()
                {
                    sigs.insert(sig);
                }
            }
            _ => {}
        }
    }

    let store_path = store_path_opt.ok_or(NarInfoError::MissingField("StorePath"))?;
    let url = url_opt.ok_or(NarInfoError::MissingField("URL"))?;
    let compression = compression_opt.ok_or(NarInfoError::MissingField("Compression"))?;
    let nar_hash = nar_hash_opt.ok_or(NarInfoError::MissingField("NarHash"))?;
    if !have_nar_size {
        return Err(NarInfoError::MissingField("NarSize"));
    }

    let ca = ca_str.as_deref().and_then(|s| s.parse().ok());

    Ok(NarInfo {
        path: store_path,
        info: UnkeyedNarInfo {
            info: UnkeyedValidPathInfo {
                deriver,
                nar_hash,
                references,
                registration_time: None,
                nar_size,
                ultimate: false,
                signatures: sigs,
                ca,
                store_dir: StoreDir::default(),
            },
            url: Some(url),
            compression: Some(compression),
            download_hash: file_hash,
            download_size: file_size,
        },
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    /// `StorePath` holds the full path, references and deriver base names,
    /// as served by cache.nixos.org and written by `harmonia_store_nar_info`.
    #[test]
    fn parse_narinfo_accepts_full_store_path() {
        let raw = b"StorePath: /nix/store/syd87l2rxw8cbsxmxl853h0r6pdwhwjr-curl-7.82.0-bin\n\
URL: nar/1bjjbgp9p4hxbjy2gs1rajk5qvbwzgsm87lqycpvxmsq0d11h5cl.nar.xz\n\
Compression: xz\n\
NarHash: sha256:1m9hzhwddwpl6kcyiyhpkbhqkdgvqrgss132f0jknsws6albmbcl\n\
NarSize: 196040\n\
References: 0jqd0rlxzra1rs38rdxl43yh6rxchgc6-curl-7.82.0\n\
Deriver: 5rwxzi7pal3qhpsyfc16gzkh939q1np6-curl-7.82.0.drv\n";

        let narinfo = parse_narinfo(raw).expect("spec-conforming narinfo should parse");
        assert_eq!(
            narinfo.path.to_string(),
            "syd87l2rxw8cbsxmxl853h0r6pdwhwjr-curl-7.82.0-bin"
        );
        assert_eq!(narinfo.info.info.references.len(), 1);
        assert!(narinfo.info.info.deriver.is_some());
    }
}

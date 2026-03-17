use std::fmt::Write as _;

use harmonia_store_core::signature::{SecretKey, fingerprint_path};
use harmonia_store_core::store_path::StoreDir;
use harmonia_utils_hash::fmt::CommonHash as _;
use secrecy::ExposeSecret as _;

use crate::Compression;

#[derive(Debug, Clone)]
pub struct NarInfo {
    pub store_path: nix_utils::StorePath,
    pub url: String,
    pub compression: Compression,
    pub file_hash: Option<String>,
    pub file_size: Option<u64>,
    pub nar_hash: String,
    pub nar_size: u64,
    pub references: Vec<nix_utils::StorePath>,
    pub deriver: Option<nix_utils::StorePath>,
    pub ca: Option<String>,
    pub sigs: Vec<String>,
}

impl NarInfo {
    #[must_use]
    pub fn new(
        path: &nix_utils::StorePath,
        path_info: nix_utils::PathInfo,
        compression: Compression,
        signing_keys: &[secrecy::SecretString],
    ) -> Self {
        let nar_hash = normalize_nar_hash(path_info.nar_hash);
        let nar_hash_url = nar_hash
            .strip_prefix("sha256:")
            .map_or_else(|| path.hash().to_string(), ToOwned::to_owned);

        let narinfo = Self {
            store_path: path.clone(),
            url: format!("nar/{}.{}", nar_hash_url, compression.ext()),
            compression,
            file_hash: None,
            file_size: None,
            nar_hash,
            nar_size: path_info.nar_size,
            references: path_info.refs,
            deriver: path_info.deriver,
            ca: path_info.ca.clone(),
            sigs: vec![],
        };

        let mut narinfo = narinfo.clear_sigs_and_sign(signing_keys);
        if narinfo.sigs.is_empty() && !path_info.sigs.is_empty() {
            narinfo.sigs = path_info.sigs;
        }

        narinfo
    }

    #[must_use]
    pub fn simple(
        path: &nix_utils::StorePath,
        path_info: nix_utils::PathInfo,
        compression: Compression,
    ) -> Self {
        let nar_hash = normalize_nar_hash(path_info.nar_hash);
        let nar_hash_url = nar_hash
            .strip_prefix("sha256:")
            .map_or_else(|| path.hash().to_string(), ToOwned::to_owned);

        Self {
            store_path: path.clone(),
            url: format!("nar/{}.{}", nar_hash_url, compression.ext()),
            compression,
            file_hash: None,
            file_size: None,
            nar_hash,
            nar_size: path_info.nar_size,
            references: path_info.refs,
            deriver: path_info.deriver,
            ca: path_info.ca,
            sigs: vec![],
        }
    }

    #[must_use]
    pub fn clear_sigs_and_sign(mut self, signing_keys: &[secrecy::SecretString]) -> Self {
        self.sigs.clear();
        if !signing_keys.is_empty()
            && let Some(fp) = self.fingerprint()
        {
            for s in signing_keys {
                if let Ok(sk) = s.expose_secret().parse::<SecretKey>() {
                    self.sigs.push(sk.sign(&fp).to_string());
                }
            }
        }
        self
    }

    #[must_use]
    fn fingerprint(&self) -> Option<Vec<u8>> {
        let store_dir = StoreDir::default();
        let refs = self.references.iter().cloned().collect();
        fingerprint_path(
            &store_dir,
            &self.store_path,
            self.nar_hash.as_bytes(),
            self.nar_size,
            &refs,
        )
        .ok()
    }

    #[must_use]
    pub fn get_ls_path(&self) -> String {
        format!("{}.ls", self.store_path.hash().to_string())
    }

    pub fn render(&self, store_dir: &StoreDir) -> Result<String, std::fmt::Error> {
        let mut o = String::with_capacity(200);
        writeln!(o, "StorePath: {}", store_dir.display(&self.store_path))?;
        writeln!(o, "URL: {}", self.url)?;
        writeln!(o, "Compression: {}", self.compression.as_str())?;
        if let Some(h) = &self.file_hash {
            writeln!(o, "FileHash: {h}")?;
        }
        if let Some(s) = self.file_size {
            writeln!(o, "FileSize: {s}")?;
        }
        writeln!(o, "NarHash: {}", self.nar_hash)?;
        writeln!(o, "NarSize: {}", self.nar_size)?;

        writeln!(
            o,
            "References: {}",
            self.references
                .iter()
                .map(nix_utils::StorePath::to_string)
                .collect::<Vec<_>>()
                .join(" ")
        )?;

        if let Some(d) = &self.deriver {
            writeln!(o, "Deriver: {}", d.to_string())?;
        }
        if let Some(ca) = &self.ca {
            writeln!(o, "CA: {ca}")?;
        }

        for sig in &self.sigs {
            writeln!(o, "Sig: {sig}")?;
        }
        Ok(o)
    }
}

/// Normalize a nar hash from the C++ FFI format (`sha256:base16`, 71 chars)
/// to the narinfo format (`sha256:nix32`, 59 chars). Passes through hashes
/// already in the correct format.
fn normalize_nar_hash(raw: String) -> String {
    // C++ nix returns "sha256:<64 hex chars>" = 71 bytes; convert to "sha256:<52 nix32 chars>"
    if raw.len() == 71 && raw.starts_with("sha256:") {
        if let Ok(hash) = raw.parse::<harmonia_utils_hash::fmt::Any<harmonia_utils_hash::Hash>>() {
            return format!("{}", hash.into_hash().as_base32());
        }
    }
    raw
}

#[derive(Debug, thiserror::Error)]
pub enum NarInfoError {
    #[error("missing required field: {0}")]
    MissingField(&'static str),
    #[error("invalid value for {field}: {value}")]
    InvalidField { field: String, value: String },
    #[error("parse error on line {line}: {reason}")]
    Line { line: usize, reason: String },
    #[error("integer parse error for {field}: {err}")]
    Int {
        field: &'static str,
        err: std::num::ParseIntError,
    },
}

impl std::str::FromStr for NarInfo {
    type Err = NarInfoError;

    #[tracing::instrument(skip(input), err)]
    #[allow(clippy::too_many_lines)]
    fn from_str(input: &str) -> Result<Self, Self::Err> {
        let mut out = Self {
            store_path: nix_utils::parse_store_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bla"),
            url: String::new(),
            compression: Compression::None,
            file_hash: None,
            file_size: None,
            nar_hash: String::new(),
            nar_size: 0,
            references: vec![],
            deriver: None,
            ca: None,
            sigs: vec![],
        };

        // Temporaries to know what was present
        let mut have_store_path = false;
        let mut have_url = false;
        let mut have_compression = false;
        let mut have_nar_hash = false;
        let mut have_nar_size = false;

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
                    out.store_path = nix_utils::parse_store_path(val);
                    have_store_path = true;
                }
                "URL" => {
                    out.url = val.to_string();
                    have_url = true;
                }
                "Compression" => {
                    out.compression = val.parse().map_err(|e| NarInfoError::InvalidField {
                        field: "Compression".into(),
                        value: e,
                    })?;
                    have_compression = true;
                }
                "FileHash" => {
                    out.file_hash = Some(val.to_string());
                }
                "FileSize" => {
                    out.file_size = Some(val.parse::<u64>().map_err(|e| NarInfoError::Int {
                        field: "FileSize",
                        err: e,
                    })?);
                }
                "NarHash" => {
                    out.nar_hash = val.to_string();
                    have_nar_hash = true;
                }
                "NarSize" => {
                    out.nar_size = val.parse::<u64>().map_err(|e| NarInfoError::Int {
                        field: "NarSize",
                        err: e,
                    })?;
                    have_nar_size = true;
                }
                "References" => {
                    let refs = val
                        .split_whitespace()
                        .filter(|s| !s.is_empty())
                        .map(nix_utils::parse_store_path)
                        .collect::<Vec<_>>();
                    out.references = refs;
                }
                "Deriver" => {
                    out.deriver = if val.is_empty() {
                        None
                    } else {
                        Some(nix_utils::parse_store_path(val))
                    };
                }
                "CA" => {
                    out.ca = if val.is_empty() {
                        None
                    } else {
                        Some(val.to_string())
                    };
                }
                "Sig" => {
                    if !val.is_empty() {
                        out.sigs.push(val.to_string());
                    }
                }
                _ => {}
            }
        }

        // Validate requireds
        if !have_store_path {
            return Err(NarInfoError::MissingField("StorePath"));
        }
        if !have_url {
            return Err(NarInfoError::MissingField("URL"));
        }
        if !have_compression {
            return Err(NarInfoError::MissingField("Compression"));
        }
        if !have_nar_hash {
            return Err(NarInfoError::MissingField("NarHash"));
        }
        if !have_nar_size {
            return Err(NarInfoError::MissingField("NarSize"));
        }

        Ok(out)
    }
}

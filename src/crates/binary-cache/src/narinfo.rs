use std::fmt::Write as _;

use secrecy::ExposeSecret as _;

use crate::Compression;

use nix_utils::BaseStore as _;

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
        store: &nix_utils::LocalStore,
        path: &nix_utils::StorePath,
        path_info: nix_utils::PathInfo,
        compression: Compression,
        signing_keys: &[secrecy::SecretString],
    ) -> Self {
        let nar_hash = if path_info.nar_hash.len() == 71 {
            nix_utils::convert_hash(
                &path_info.nar_hash[7..],
                Some(nix_utils::HashAlgorithm::SHA256),
                nix_utils::HashFormat::Nix32,
            )
            .unwrap_or(path_info.nar_hash)
        } else {
            path_info.nar_hash
        };
        let nar_hash_url = nar_hash
            .strip_prefix("sha256:")
            .map_or_else(|| path.hash_part(), |h| h);

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

        let mut narinfo = narinfo.clear_sigs_and_sign(store, signing_keys);
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
        let nar_hash = if path_info.nar_hash.len() == 71 {
            nix_utils::convert_hash(
                &path_info.nar_hash[7..],
                Some(nix_utils::HashAlgorithm::SHA256),
                nix_utils::HashFormat::Nix32,
            )
            .unwrap_or(path_info.nar_hash)
        } else {
            path_info.nar_hash
        };
        let nar_hash_url = nar_hash
            .strip_prefix("sha256:")
            .map_or_else(|| path.hash_part(), |h| h);

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
    pub fn clear_sigs_and_sign(
        mut self,
        store: &nix_utils::LocalStore,
        signing_keys: &[secrecy::SecretString],
    ) -> Self {
        self.sigs.clear(); // if we call this sign, we dont trust the signatures
        if !signing_keys.is_empty()
            && let Some(fp) = self.fingerprint_path(store)
        {
            for s in signing_keys {
                self.sigs
                    .push(nix_utils::sign_string(s.expose_secret(), &fp));
            }
        }
        self
    }

    #[must_use]
    fn fingerprint_path(&self, store: &nix_utils::LocalStore) -> Option<String> {
        let root_store_dir = nix_utils::get_store_dir();
        let abs_path = store.print_store_path(&self.store_path);

        if abs_path[0..root_store_dir.len()] != root_store_dir || &self.nar_hash[0..7] != "sha256:"
        {
            return None;
        }

        if self.nar_hash.len() != 59 {
            return None;
        }

        let refs = self
            .references
            .iter()
            .map(|r| store.print_store_path(r))
            .collect::<Vec<_>>();
        for r in &refs {
            if r[0..root_store_dir.len()] != root_store_dir {
                return None;
            }
        }

        Some(format!(
            "1;{};{};{};{}",
            abs_path,
            self.nar_hash,
            self.nar_size,
            refs.join(",")
        ))
    }

    #[must_use]
    pub fn get_ls_path(&self) -> String {
        format!("{}.ls", self.store_path.hash_part())
    }

    pub fn render(&self, store: &nix_utils::LocalStore) -> Result<String, std::fmt::Error> {
        let mut o = String::with_capacity(200);
        writeln!(o, "StorePath: {}", store.print_store_path(&self.store_path))?;
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
                .map(nix_utils::StorePath::base_name)
                .collect::<Vec<_>>()
                .join(" ")
        )?;

        if let Some(d) = &self.deriver {
            writeln!(o, "Deriver: {}", d.base_name())?;
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
            store_path: nix_utils::StorePath::new("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bla"),
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
                    out.store_path = nix_utils::StorePath::new(val);
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
                        .map(nix_utils::StorePath::new)
                        .collect::<Vec<_>>();
                    out.references = refs;
                }
                "Deriver" => {
                    out.deriver = if val.is_empty() {
                        None
                    } else {
                        Some(nix_utils::StorePath::new(val))
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

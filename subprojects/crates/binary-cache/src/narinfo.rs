use harmonia_store_nar_info::UnkeyedNarInfo;
use harmonia_store_path::{StoreDir, StorePath};
use harmonia_store_path_info::fingerprint_path;
use harmonia_store_path_info::{NarHash, UnkeyedValidPathInfo};
use harmonia_utils_hash::Hash;
use harmonia_utils_hash::HashFormat as _;
use harmonia_utils_signature::SecretKey;
use secrecy::ExposeSecret as _;

use crate::Compression;

pub use harmonia_store_nar_info::NarInfo;

/// Re-export the harmonia narinfo formatter and parser.
pub use harmonia_store_nar_info::{format_narinfo_txt, parse_narinfo_txt};

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

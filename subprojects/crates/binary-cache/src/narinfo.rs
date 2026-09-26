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

/// Build a `NarInfo` from a `PathInfo` (`UnkeyedValidPathInfo`), adding a signature per signing
/// key to the signatures it already carries.
#[must_use]
pub fn narinfo_from_path_info(
    path: &StorePath,
    path_info: UnkeyedValidPathInfo,
    compression: Compression,
    store_dir: &StoreDir,
    signing_keys: &[secrecy::SecretString],
) -> NarInfo {
    sign_narinfo(
        narinfo_simple(path, path_info, compression),
        store_dir,
        signing_keys,
    )
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

/// Add a signature per signing key. Like Nix's `ValidPathInfo::sign`, this keeps existing
/// signatures, e.g. those from the builder's `secret-key-files`.
#[must_use]
pub fn sign_narinfo(
    mut narinfo: NarInfo,
    store_dir: &StoreDir,
    signing_keys: &[secrecy::SecretString],
) -> NarInfo {
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
    narinfo
}

/// Return the `.ls` listing key for this narinfo.
#[must_use]
pub fn get_ls_path(narinfo: &NarInfo) -> String {
    format!("{}.ls", narinfo.path.hash())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use std::collections::BTreeSet;

    use harmonia_utils_signature::Signature;

    use super::*;

    #[test]
    fn sign_narinfo_keeps_existing_signatures() {
        let store_dir = StoreDir::default();
        let path: StorePath = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello".parse().unwrap();
        let builder_sig: Signature = "builder-1:0CpHca+06TwFp9VkMyz5OaphT3E8mnS+1SWymYlvFaghKSYPCMQ66TS1XPAr1+y9rfQZPLaHrBjjnIRktE/nAA==".parse().unwrap();
        let path_info = UnkeyedValidPathInfo {
            deriver: None,
            nar_hash: NarHash::from_slice(&[0xab; 32]).unwrap(),
            references: BTreeSet::new(),
            registration_time: None,
            nar_size: 42,
            ultimate: false,
            signatures: BTreeSet::from([builder_sig.clone()]),
            ca: None,
            store_dir: store_dir.clone(),
        };
        let cache_key = SecretKey::generate("cache-1".into()).unwrap();

        let narinfo = narinfo_from_path_info(
            &path,
            path_info,
            Compression::None,
            &store_dir,
            &[cache_key.to_string().into()],
        );

        let sigs = &narinfo.info.info.signatures;
        assert_eq!(sigs.len(), 2);
        assert!(sigs.contains(&builder_sig));
        assert!(sigs.iter().any(|s| s.name() == "cache-1"));
    }
}

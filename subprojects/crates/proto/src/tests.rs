use super::*;
use std::collections::{BTreeMap, BTreeSet};

use harmonia_store_content_address::ContentAddress;
use harmonia_store_path::{StoreDir, StorePath};
use harmonia_store_path_info::NarHash;
use harmonia_utils_hash::{Algorithm, Hash, Sha256};
use harmonia_utils_signature::Signature;

use super::{BuildMetric, BuildProduct, NixSupport};

fn test_store_dir() -> StoreDir {
    StoreDir::default()
}

fn test_sig() -> Signature {
    "cache.nixos.org-1:0CpHca+06TwFp9VkMyz5OaphT3E8mnS+1SWymYlvFaghKSYPCMQ66TS1XPAr1+y9rfQZPLaHrBjjnIRktE/nAA==".parse().unwrap()
}

fn test_path() -> StorePath {
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello".parse().unwrap()
}

fn test_unkeyed_valid_path_info() -> harmonia_store_path_info::UnkeyedValidPathInfo {
    harmonia_store_path_info::UnkeyedValidPathInfo {
        deriver: Some("cccccccccccccccccccccccccccccccc-drv.drv".parse().unwrap()),
        nar_hash: NarHash::from_slice(&[0xab; 32]).unwrap(),
        references: BTreeSet::from(["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-dep".parse().unwrap()]),
        registration_time: std::num::NonZero::new(1700000000),
        nar_size: 42000,
        ultimate: true,
        signatures: BTreeSet::from([test_sig()]),
        ca: Some(ContentAddress::NixArchive(
            Hash::from_slice(Algorithm::SHA256, &[0x55; 32]).unwrap(),
        )),
        store_dir: test_store_dir(),
    }
}

fn roundtrip<A, B>(original: &A) -> A
where
    for<'a> &'a A: Into<B>,
    B: TryInto<A>,
    <B as TryInto<A>>::Error: std::fmt::Debug,
{
    let proto: B = original.into();
    proto.try_into().unwrap()
}

// -- Hash round-trips --

#[test]
fn hash_roundtrip_sha256() {
    let h = Hash::from_slice(Algorithm::SHA256, &[0xab; 32]).unwrap();
    assert_eq!(roundtrip::<Hash, nix::store::v1::Hash>(&h), h);
}

#[test]
fn hash_roundtrip_sha512() {
    let h = Hash::from_slice(Algorithm::SHA512, &[0xcd; 64]).unwrap();
    assert_eq!(roundtrip::<Hash, nix::store::v1::Hash>(&h), h);
}

#[test]
fn signature_roundtrip() {
    let sig: Signature = test_sig();
    assert_eq!(roundtrip::<Signature, nix::store::v1::Signature>(&sig), sig);
}

#[test]
fn content_address_roundtrip_text() {
    let ca = ContentAddress::Text(Sha256::from_slice(&[0x11; 32]).unwrap());
    assert_eq!(
        roundtrip::<ContentAddress, nix::store::v1::ContentAddress>(&ca),
        ca
    );
}

#[test]
fn content_address_roundtrip_flat() {
    let ca = ContentAddress::Flat(Hash::from_slice(Algorithm::SHA256, &[0x22; 32]).unwrap());
    assert_eq!(
        roundtrip::<ContentAddress, nix::store::v1::ContentAddress>(&ca),
        ca
    );
}

#[test]
fn content_address_roundtrip_nar() {
    let ca = ContentAddress::NixArchive(Hash::from_slice(Algorithm::SHA256, &[0x33; 32]).unwrap());
    assert_eq!(
        roundtrip::<ContentAddress, nix::store::v1::ContentAddress>(&ca),
        ca
    );
}

// -- RelativeStorePath round-trips --

#[test]
fn relative_store_path_roundtrip() {
    let rsp = store_path_utils::RelativeStorePath {
        base_path: test_path(),
        relative_path: "share/doc/manual".into(),
    };
    assert_eq!(
        roundtrip::<store_path_utils::RelativeStorePath, RelativeStorePath>(&rsp),
        rsp
    );
}

#[test]
fn relative_store_path_roundtrip_bare() {
    let rsp = store_path_utils::RelativeStorePath {
        base_path: test_path(),
        relative_path: "".into(),
    };
    assert_eq!(
        roundtrip::<store_path_utils::RelativeStorePath, RelativeStorePath>(&rsp),
        rsp
    );
}

// -- UnkeyedValidPathInfo round-trips --

#[test]
fn unkeyed_valid_path_info_roundtrip() {
    let v = test_unkeyed_valid_path_info();
    assert_eq!(
        roundtrip::<harmonia_store_path_info::UnkeyedValidPathInfo, UnkeyedValidPathInfo>(&v),
        v
    );
}

// -- UnkeyedNarInfo round-trips --

#[test]
fn unkeyed_nar_info_roundtrip() {
    let v = harmonia_store_nar_info::UnkeyedNarInfo {
        info: test_unkeyed_valid_path_info(),
        url: Some("nar/foo.nar.zst".to_owned()),
        compression: Some("zstd".to_owned()),
        download_hash: Some(Hash::from_slice(Algorithm::SHA256, &[0xee; 32]).unwrap()),
        download_size: Some(500),
    };
    assert_eq!(
        roundtrip::<harmonia_store_nar_info::UnkeyedNarInfo, UnkeyedNarInfo>(&v),
        v
    );
}

// -- NarInfo round-trips --

#[test]
fn narinfo_roundtrip_minimal() {
    let ni = harmonia_store_nar_info::NarInfo {
        path: test_path(),
        info: harmonia_store_nar_info::UnkeyedNarInfo {
            info: harmonia_store_path_info::UnkeyedValidPathInfo {
                deriver: None,
                nar_hash: NarHash::from_slice(&[0xab; 32]).unwrap(),
                references: BTreeSet::from(["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-dep"
                    .parse()
                    .unwrap()]),
                registration_time: None,
                nar_size: 12345,
                ultimate: false,
                signatures: BTreeSet::new(),
                ca: None,
                store_dir: test_store_dir(),
            },
            url: Some("nar/abc.nar".to_owned()),
            compression: Some("zstd".to_owned()),
            download_hash: None,
            download_size: None,
        },
    };
    assert_eq!(
        roundtrip::<harmonia_store_nar_info::NarInfo, NarInfo>(&ni),
        ni
    );
}

#[test]
fn narinfo_roundtrip_with_all_fields() {
    let ni = harmonia_store_nar_info::NarInfo {
        path: test_path(),
        info: harmonia_store_nar_info::UnkeyedNarInfo {
            info: test_unkeyed_valid_path_info(),
            url: Some("nar/xyz.nar.zst".to_owned()),
            compression: Some("zstd".to_owned()),
            download_hash: Some(Hash::from_slice(Algorithm::SHA256, &[0xee; 32]).unwrap()),
            download_size: Some(9999),
        },
    };
    assert_eq!(
        roundtrip::<harmonia_store_nar_info::NarInfo, NarInfo>(&ni),
        ni
    );
}

#[test]
fn narinfo_missing_path_fails() {
    let proto = NarInfo {
        path: None,
        info: Some(nix::store::v1::UnkeyedNarInfo {
            info: None,
            url: String::new(),
            compression: String::new(),
            download_hash: None,
            download_size: None,
        }),
    };
    let result: Result<harmonia_store_nar_info::NarInfo, _> = proto.try_into();
    assert!(result.is_err());
}

#[test]
fn narinfo_missing_info_fails() {
    let proto = NarInfo {
        path: Some(ProtoStorePath::from(test_path())),
        info: None,
    };
    let result: Result<harmonia_store_nar_info::NarInfo, _> = proto.try_into();
    assert!(result.is_err());
}

// -- NixSupport round-trips --

fn owned_roundtrip<A, B>(original: A) -> A
where
    A: Clone + Into<B>,
    B: TryInto<A>,
    <B as TryInto<A>>::Error: std::fmt::Debug,
{
    let proto: B = original.clone().into();
    proto.try_into().unwrap()
}

#[test]
fn build_product_roundtrip() {
    let bp = nix_support::BuildProduct {
        path: store_path_utils::RelativeStorePath {
            base_path: test_path(),
            relative_path: "bin/hello".into(),
        },
        default_path: "bin/hello".into(),
        r#type: "doc".into(),
        subtype: "readme".into(),
        name: "README.md".into(),
        is_regular: true,
        sha256hash: Some(Sha256::from_slice(&[0xab; 32]).unwrap()),
        file_size: Some(1024),
    };
    assert_eq!(
        owned_roundtrip::<nix_support::BuildProduct, BuildProduct>(bp.clone()),
        bp
    );
}

#[test]
fn build_product_roundtrip_no_hash() {
    let bp = nix_support::BuildProduct {
        path: store_path_utils::RelativeStorePath {
            base_path: test_path(),
            relative_path: "".into(),
        },
        default_path: String::new(),
        r#type: "nix-build".into(),
        subtype: "out-path".into(),
        name: "output".into(),
        is_regular: false,
        sha256hash: None,
        file_size: None,
    };
    assert_eq!(
        owned_roundtrip::<nix_support::BuildProduct, BuildProduct>(bp.clone()),
        bp
    );
}

#[test]
fn build_metric_roundtrip() {
    let bm = nix_support::BuildMetric {
        unit: Some("seconds".into()),
        value: 42.5,
    };
    assert_eq!(
        owned_roundtrip::<nix_support::BuildMetric, BuildMetric>(bm.clone()),
        bm
    );
}

#[test]
fn nix_support_roundtrip() {
    let ns = nix_support::NixSupport {
        failed: false,
        hydra_release_name: Some("hello-1.0".into()),
        metrics: BTreeMap::from([(
            "build_time".into(),
            nix_support::BuildMetric {
                unit: Some("seconds".into()),
                value: 42.5,
            },
        )]),
        products: vec![nix_support::BuildProduct {
            path: store_path_utils::RelativeStorePath {
                base_path: test_path(),
                relative_path: "bin/hello".into(),
            },
            default_path: "bin/hello".into(),
            r#type: "doc".into(),
            subtype: "readme".into(),
            name: "README.md".into(),
            is_regular: true,
            sha256hash: Some(Sha256::from_slice(&[0xab; 32]).unwrap()),
            file_size: Some(1024),
        }],
    };
    assert_eq!(
        owned_roundtrip::<nix_support::NixSupport, NixSupport>(ns.clone()),
        ns
    );
}

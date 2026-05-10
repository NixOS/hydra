use super::*;
use std::collections::BTreeSet;

use harmonia_store_core::store_path::StoreDir;
use harmonia_store_path_info::NarHash;

fn roundtrip(original: &harmonia_store_nar_info::NarInfo) -> harmonia_store_nar_info::NarInfo {
    let proto: NarInfo = original.clone().into();
    proto.try_into().unwrap()
}

#[test]
fn narinfo_roundtrip_minimal() {
    let ni = harmonia_store_nar_info::NarInfo {
        path: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello".parse().unwrap(),
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
                store_dir: StoreDir::new("/nix/store").unwrap(),
            },
            url: Some("nar/abc.nar".to_owned()),
            compression: Some("zstd".to_owned()),
            download_hash: None,
            download_size: None,
        },
    };
    assert_eq!(roundtrip(&ni), ni);
}

#[test]
fn narinfo_roundtrip_with_download_info() {
    let ni = harmonia_store_nar_info::NarInfo {
        path: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-hello".parse().unwrap(),
        info: harmonia_store_nar_info::UnkeyedNarInfo {
            info: harmonia_store_path_info::UnkeyedValidPathInfo {
                deriver: Some("cccccccccccccccccccccccccccccccc-drv.drv".parse().unwrap()),
                nar_hash: NarHash::from_slice(&[0xcd; 32]).unwrap(),
                references: BTreeSet::new(),
                registration_time: None,
                nar_size: 99999,
                ultimate: false,
                signatures: BTreeSet::new(),
                ca: None,
                store_dir: StoreDir::new("/nix/store").unwrap(),
            },
            url: Some("nar/xyz.nar.zst".to_owned()),
            compression: Some("zstd".to_owned()),
            download_hash: parse_hash("sha256:1b2m2y8asgthdy6knt0d3k5z6s8p7nd0df8sm3k"),
            download_size: Some(9999),
        },
    };
    assert_eq!(roundtrip(&ni), ni);
}

#[test]
fn narinfo_missing_path_fails() {
    let proto = NarInfo {
        path: None,
        info: Some(nix::store::v1::UnkeyedNarInfo {
            info: None,
            url: String::new(),
            compression: String::new(),
            file_hash: String::new(),
            file_size: 0,
        }),
    };
    let result: Result<harmonia_store_nar_info::NarInfo, _> = proto.try_into();
    assert!(result.is_err());
}

#[test]
fn narinfo_missing_info_fails() {
    let proto = NarInfo {
        path: Some(ProtoStorePath::from(
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-x"
                .parse::<harmonia_store_core::store_path::StorePath>()
                .unwrap(),
        )),
        info: None,
    };
    let result: Result<harmonia_store_nar_info::NarInfo, _> = proto.try_into();
    assert!(result.is_err());
}

// We need to allow pedantic here because of generated code
#![allow(clippy::pedantic, unused_qualifications)]

pub mod store_path;

pub use store_path::ProtoStorePath;

pub mod nix {
    pub mod store {
        pub mod v1 {
            tonic::include_proto!("nix.store.v1");
        }
    }
}

pub use nix::store::v1::{
    NarInfo, RelativeStorePath, StorePaths, UnkeyedNarInfo, UnkeyedValidPathInfo, ValidPathInfo,
};

tonic::include_proto!("runner.v1");

include!(concat!(env!("OUT_DIR"), "/proto_version.rs"));

pub const FILE_DESCRIPTOR_SET: &[u8] = tonic::include_file_descriptor_set!("streaming_descriptor");

impl From<store_path_utils::RelativeStorePath> for RelativeStorePath {
    fn from(r: store_path_utils::RelativeStorePath) -> Self {
        Self {
            store_path: Some(ProtoStorePath::from(r.base_path)),
            sub_path: r.relative_path.into(),
        }
    }
}

impl TryFrom<RelativeStorePath> for store_path_utils::RelativeStorePath {
    type Error = &'static str;

    fn try_from(r: RelativeStorePath) -> Result<Self, Self::Error> {
        let store_path = r.store_path.ok_or("missing store_path")?;
        Ok(Self {
            base_path: store_path.0,
            relative_path: r.sub_path.into(),
        })
    }
}

// -- NarInfo / ValidPathInfo conversions --

use harmonia_utils_hash::Hash;
use harmonia_utils_hash::fmt::CommonHash as _;

fn parse_hash(raw: &str) -> Option<Hash> {
    raw.parse::<harmonia_utils_hash::fmt::Any<Hash>>()
        .map(harmonia_utils_hash::fmt::Any::into_hash)
        .ok()
}

impl From<harmonia_store_path_info::UnkeyedValidPathInfo> for UnkeyedValidPathInfo {
    fn from(v: harmonia_store_path_info::UnkeyedValidPathInfo) -> Self {
        let nar_hash_obj: Hash = v.nar_hash.into();
        Self {
            deriver: v.deriver.map(ProtoStorePath::from),
            nar_hash: format!("{}", nar_hash_obj.as_base32()),
            references: v.references.into_iter().map(ProtoStorePath::from).collect(),
            registration_time: v.registration_time.map(|t| t.get()),
            nar_size: v.nar_size,
            ultimate: v.ultimate,
            signatures: v.signatures.iter().map(|s| s.to_string()).collect(),
            ca: v.ca.map(|ca| ca.to_string()),
            store_dir: v.store_dir.to_string(),
        }
    }
}

impl From<harmonia_store_nar_info::UnkeyedNarInfo> for UnkeyedNarInfo {
    fn from(n: harmonia_store_nar_info::UnkeyedNarInfo) -> Self {
        Self {
            info: Some(n.info.into()),
            url: n.url.unwrap_or_default(),
            compression: n.compression.unwrap_or_default(),
            file_hash: n
                .download_hash
                .map(|h| format!("{}", h.as_base32()))
                .unwrap_or_default(),
            file_size: n.download_size.unwrap_or(0),
        }
    }
}

impl From<harmonia_store_nar_info::NarInfo> for NarInfo {
    fn from(n: harmonia_store_nar_info::NarInfo) -> Self {
        Self {
            path: Some(ProtoStorePath::from(n.path)),
            info: Some(n.info.into()),
        }
    }
}

/// Error type for converting proto `NarInfo` to harmonia `NarInfo`.
#[derive(Debug, Clone)]
pub struct NarInfoConvertError(pub &'static str);

impl std::fmt::Display for NarInfoConvertError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl TryFrom<UnkeyedValidPathInfo> for harmonia_store_path_info::UnkeyedValidPathInfo {
    type Error = NarInfoConvertError;

    fn try_from(v: UnkeyedValidPathInfo) -> Result<Self, Self::Error> {
        let raw_hash = parse_hash(&v.nar_hash).ok_or(NarInfoConvertError("invalid nar_hash"))?;
        let nar_hash = harmonia_store_path_info::NarHash::try_from(raw_hash)
            .map_err(|_| NarInfoConvertError("nar_hash is not sha256"))?;

        Ok(Self {
            deriver: v.deriver.map(|p| p.0),
            nar_hash,
            references: v.references.into_iter().map(|p| p.0).collect(),
            registration_time: std::num::NonZero::new(v.registration_time.unwrap_or(0)),
            nar_size: v.nar_size,
            ultimate: v.ultimate,
            signatures: v
                .signatures
                .into_iter()
                .filter_map(|s| s.parse().ok())
                .collect(),
            ca: v.ca.as_deref().and_then(|s| s.parse().ok()),
            store_dir: harmonia_store_core::store_path::StoreDir::new(&v.store_dir)
                .unwrap_or_default(),
        })
    }
}

impl TryFrom<UnkeyedNarInfo> for harmonia_store_nar_info::UnkeyedNarInfo {
    type Error = NarInfoConvertError;

    fn try_from(n: UnkeyedNarInfo) -> Result<Self, Self::Error> {
        let info = n
            .info
            .ok_or(NarInfoConvertError("missing info"))?
            .try_into()?;
        Ok(Self {
            info,
            url: if n.url.is_empty() { None } else { Some(n.url) },
            compression: if n.compression.is_empty() {
                None
            } else {
                Some(n.compression)
            },
            download_hash: parse_hash(&n.file_hash),
            download_size: if n.file_size == 0 {
                None
            } else {
                Some(n.file_size)
            },
        })
    }
}

impl TryFrom<NarInfo> for harmonia_store_nar_info::NarInfo {
    type Error = NarInfoConvertError;

    fn try_from(n: NarInfo) -> Result<Self, Self::Error> {
        let path = n.path.ok_or(NarInfoConvertError("missing path"))?.0;
        let info = n
            .info
            .ok_or(NarInfoConvertError("missing info"))?
            .try_into()?;
        Ok(Self { path, info })
    }
}

#[cfg(test)]
mod tests;

#[cfg(feature = "db")]
impl From<StepStatus> for db::models::StepStatus {
    fn from(item: StepStatus) -> Self {
        match item {
            StepStatus::Preparing => Self::Preparing,
            StepStatus::Connecting => Self::Connecting,
            StepStatus::SeningInputs => Self::SendingInputs,
            StepStatus::Building => Self::Building,
            StepStatus::WaitingForLocalSlot => Self::WaitingForLocalSlot,
            StepStatus::ReceivingOutputs => Self::ReceivingOutputs,
            StepStatus::PostProcessing => Self::PostProcessing,
        }
    }
}

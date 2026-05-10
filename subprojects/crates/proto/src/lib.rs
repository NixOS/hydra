// We need to allow pedantic here because of generated code
#![allow(clippy::pedantic, unused_qualifications)]

pub mod store_path;

pub use store_path::ProtoStorePath;

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

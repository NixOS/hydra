// We need to allow pedantic here because of generated code
#![allow(clippy::pedantic, unused_qualifications)]

use harmonia_utils_hash::HashView;

pub mod store_path;

pub use store_path::ProtoStorePath;

pub mod nix {
    pub mod store {
        pub mod v1 {
            tonic::include_proto!("nix.store.v1");
        }
        pub mod derivation {
            pub mod v1 {
                tonic::include_proto!("nix.store.derivation.v1");
            }
        }
    }
}

pub use nix::store::v1::{
    NarInfo, RelativeStorePath, StorePaths, UnkeyedNarInfo, UnkeyedValidPathInfo, ValidPathInfo,
};

tonic::include_proto!("runner.v1");

include!(concat!(env!("OUT_DIR"), "/proto_version.rs"));

pub const FILE_DESCRIPTOR_SET: &[u8] = tonic::include_file_descriptor_set!("streaming_descriptor");

impl From<&store_path_utils::RelativeStorePath> for RelativeStorePath {
    fn from(r: &store_path_utils::RelativeStorePath) -> Self {
        Self {
            store_path: Some(ProtoStorePath::from(&r.base_path)),
            sub_path: r.relative_path.to_string(),
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

// -- Conversions between proto types and harmonia types --

/// Error type for converting proto types to harmonia types.
#[derive(Debug, Clone)]
pub struct NarInfoConvertError(pub &'static str);

impl std::fmt::Display for NarInfoConvertError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}

impl std::error::Error for NarInfoConvertError {}

// -- Hash Algorithm --

impl From<harmonia_utils_hash::Algorithm> for nix::store::v1::hash::Algorithm {
    fn from(algo: harmonia_utils_hash::Algorithm) -> Self {
        use harmonia_utils_hash::Algorithm;
        match algo {
            Algorithm::SHA256 => Self::Sha256,
            Algorithm::SHA512 => Self::Sha512,
            Algorithm::SHA1 => Self::Sha1,
            Algorithm::MD5 => Self::Md5,
            Algorithm::BLAKE3 => Self::Blake3,
        }
    }
}

impl From<nix::store::v1::hash::Algorithm> for harmonia_utils_hash::Algorithm {
    fn from(algo: nix::store::v1::hash::Algorithm) -> Self {
        match algo {
            nix::store::v1::hash::Algorithm::Sha256 => Self::SHA256,
            nix::store::v1::hash::Algorithm::Sha512 => Self::SHA512,
            nix::store::v1::hash::Algorithm::Sha1 => Self::SHA1,
            nix::store::v1::hash::Algorithm::Md5 => Self::MD5,
            nix::store::v1::hash::Algorithm::Blake3 => Self::BLAKE3,
        }
    }
}

// -- Hash --

impl From<&harmonia_utils_hash::Hash> for nix::store::v1::Hash {
    fn from(h: &harmonia_utils_hash::Hash) -> Self {
        Self {
            algorithm: nix::store::v1::hash::Algorithm::from(h.algorithm()) as i32,
            digest: h.as_ref().to_vec(),
        }
    }
}

impl TryFrom<nix::store::v1::Hash> for harmonia_utils_hash::Hash {
    type Error = &'static str;

    fn try_from(h: nix::store::v1::Hash) -> Result<Self, Self::Error> {
        let algo: harmonia_utils_hash::Algorithm =
            nix::store::v1::hash::Algorithm::try_from(h.algorithm)
                .map_err(|_| "unknown hash algorithm")?
                .into();
        harmonia_utils_hash::Hash::from_slice(algo, &h.digest)
            .map_err(|_| "invalid hash digest length")
    }
}

// -- Signature --

impl From<&harmonia_utils_signature::Signature> for nix::store::v1::Signature {
    fn from(sig: &harmonia_utils_signature::Signature) -> Self {
        Self {
            key_name: sig.key_name.clone(),
            sig: sig.sig.to_string(),
        }
    }
}

impl TryFrom<nix::store::v1::Signature> for harmonia_utils_signature::Signature {
    type Error = &'static str;

    fn try_from(sig: nix::store::v1::Signature) -> Result<Self, Self::Error> {
        Ok(Self {
            key_name: sig.key_name.clone(),
            sig: sig.sig.parse().map_err(|_| "invalid signature")?,
        })
    }
}

// -- ContentAddress --

impl From<&harmonia_store_content_address::ContentAddress> for nix::store::v1::ContentAddress {
    fn from(ca: &harmonia_store_content_address::ContentAddress) -> Self {
        use harmonia_store_content_address::ContentAddress as CA;
        match ca {
            CA::Text(h) => Self {
                method: nix::store::v1::content_address::Method::Text as i32,
                hash: Some(nix::store::v1::Hash::from(
                    &harmonia_utils_hash::Hash::from(*h),
                )),
            },
            CA::Flat(h) => Self {
                method: nix::store::v1::content_address::Method::Flat as i32,
                hash: Some(nix::store::v1::Hash::from(h)),
            },
            CA::NixArchive(h) => Self {
                method: nix::store::v1::content_address::Method::NixArchive as i32,
                hash: Some(nix::store::v1::Hash::from(h)),
            },
        }
    }
}

impl TryFrom<nix::store::v1::ContentAddress> for harmonia_store_content_address::ContentAddress {
    type Error = &'static str;

    fn try_from(ca: nix::store::v1::ContentAddress) -> Result<Self, Self::Error> {
        use harmonia_store_content_address::ContentAddress as CA;
        let hash: harmonia_utils_hash::Hash = ca.hash.ok_or("missing CA hash")?.try_into()?;
        match nix::store::v1::content_address::Method::try_from(ca.method) {
            Ok(nix::store::v1::content_address::Method::Text) => {
                let sha256 = harmonia_utils_hash::Sha256::try_from(hash)
                    .map_err(|_| "Text CA requires SHA256")?;
                Ok(CA::Text(sha256))
            }
            Ok(nix::store::v1::content_address::Method::Flat) => Ok(CA::Flat(hash)),
            Ok(nix::store::v1::content_address::Method::NixArchive) => Ok(CA::NixArchive(hash)),
            Err(_) => Err("unknown CA method"),
        }
    }
}

// -- ContentAddressMethodAlgorithm --

impl From<&harmonia_store_content_address::ContentAddressMethodAlgorithm>
    for nix::store::v1::ContentAddressMethodAlgorithm
{
    fn from(ca: &harmonia_store_content_address::ContentAddressMethodAlgorithm) -> Self {
        use harmonia_store_content_address::ContentAddressMethodAlgorithm as CAMA;
        match ca {
            CAMA::Text => Self {
                method: nix::store::v1::content_address::Method::Text as i32,
                algorithm: nix::store::v1::hash::Algorithm::Sha256 as i32,
            },
            CAMA::Flat(algo) => Self {
                method: nix::store::v1::content_address::Method::Flat as i32,
                algorithm: nix::store::v1::hash::Algorithm::from(*algo) as i32,
            },
            CAMA::NixArchive(algo) => Self {
                method: nix::store::v1::content_address::Method::NixArchive as i32,
                algorithm: nix::store::v1::hash::Algorithm::from(*algo) as i32,
            },
        }
    }
}

impl TryFrom<nix::store::v1::ContentAddressMethodAlgorithm>
    for harmonia_store_content_address::ContentAddressMethodAlgorithm
{
    type Error = &'static str;

    fn try_from(ca: nix::store::v1::ContentAddressMethodAlgorithm) -> Result<Self, Self::Error> {
        use harmonia_store_content_address::ContentAddressMethodAlgorithm as CAMA;
        let method = nix::store::v1::content_address::Method::try_from(ca.method)
            .map_err(|_| "unknown content address method")?;
        let algo: harmonia_utils_hash::Algorithm =
            nix::store::v1::hash::Algorithm::try_from(ca.algorithm)
                .map_err(|_| "unknown hash algorithm")?
                .into();
        match method {
            nix::store::v1::content_address::Method::Text => Ok(CAMA::Text),
            nix::store::v1::content_address::Method::Flat => Ok(CAMA::Flat(algo)),
            nix::store::v1::content_address::Method::NixArchive => Ok(CAMA::NixArchive(algo)),
        }
    }
}

// -- DerivationOutput --

impl From<&harmonia_store_derivation::derivation::DerivationOutput>
    for nix::store::derivation::v1::Output
{
    fn from(o: &harmonia_store_derivation::derivation::DerivationOutput) -> Self {
        use harmonia_store_derivation::derivation::DerivationOutput as DO;
        use nix::store::derivation::v1::output::Output;
        Self {
            output: Some(match o {
                DO::InputAddressed(p) => Output::InputAddressed(ProtoStorePath::from(p)),
                DO::CAFixed(ca) => Output::CaFixed(nix::store::v1::ContentAddress::from(ca)),
                DO::Deferred => Output::Deferred(nix::store::derivation::v1::Unit {}),
                DO::CAFloating(cama) => {
                    Output::CaFloating(nix::store::v1::ContentAddressMethodAlgorithm::from(cama))
                }
                DO::Impure(cama) => {
                    Output::Impure(nix::store::v1::ContentAddressMethodAlgorithm::from(cama))
                }
            }),
        }
    }
}

impl TryFrom<nix::store::derivation::v1::Output>
    for harmonia_store_derivation::derivation::DerivationOutput
{
    type Error = &'static str;

    fn try_from(o: nix::store::derivation::v1::Output) -> Result<Self, Self::Error> {
        use harmonia_store_derivation::derivation::DerivationOutput as DO;
        use nix::store::derivation::v1::output::Output;
        match o.output.ok_or("missing DerivationOutput variant")? {
            Output::InputAddressed(p) => Ok(DO::InputAddressed(p.0)),
            Output::CaFixed(ca) => Ok(DO::CAFixed(ca.try_into()?)),
            Output::Deferred(_) => Ok(DO::Deferred),
            Output::CaFloating(cama) => Ok(DO::CAFloating(cama.try_into()?)),
            Output::Impure(cama) => Ok(DO::Impure(cama.try_into()?)),
        }
    }
}

// -- BasicDerivation --

impl From<&harmonia_store_derivation::derivation::BasicDerivation>
    for nix::store::derivation::v1::Basic
{
    fn from(d: &harmonia_store_derivation::derivation::BasicDerivation) -> Self {
        Self {
            name: d.name.to_string(),
            outputs: d
                .outputs
                .iter()
                .map(|(name, output)| {
                    (
                        name.to_string(),
                        nix::store::derivation::v1::Output::from(output),
                    )
                })
                .collect(),
            inputs: d.inputs.iter().map(ProtoStorePath::from).collect(),
            platform: d.platform.to_vec(),
            builder: d.builder.to_vec(),
            args: d.args.iter().map(|a| a.to_vec()).collect(),
            env: d
                .env
                .iter()
                .map(|(k, v)| (std::str::from_utf8(k).unwrap_or("").to_owned(), v.to_vec()))
                .collect(),
            structured_attrs: d
                .structured_attrs
                .as_ref()
                .map(|sa| serde_json::to_string(&sa.attrs).unwrap_or_default()),
        }
    }
}

impl TryFrom<nix::store::derivation::v1::Basic>
    for harmonia_store_derivation::derivation::BasicDerivation
{
    type Error = String;

    fn try_from(d: nix::store::derivation::v1::Basic) -> Result<Self, Self::Error> {
        use bytes::Bytes as ByteString;
        use harmonia_store_derivation::derivation::{DerivationOutput, StructuredAttrs};
        use harmonia_store_derivation::derived_path::OutputName;

        let name = d
            .name
            .parse()
            .map_err(|e| format!("invalid derivation name: {e}"))?;

        let outputs = d
            .outputs
            .into_iter()
            .map(|(k, v)| {
                let name: OutputName =
                    k.parse().map_err(|e| format!("invalid output name: {e}"))?;
                let output: DerivationOutput = v.try_into().map_err(|e: &str| e.to_owned())?;
                Ok((name, output))
            })
            .collect::<Result<_, String>>()?;

        let inputs = d.inputs.into_iter().map(|p| p.0).collect();

        let structured_attrs = d
            .structured_attrs
            .map(|s| {
                let attrs: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&s)
                    .map_err(|e| format!("invalid structured_attrs JSON: {e}"))?;
                Ok::<_, String>(StructuredAttrs { attrs })
            })
            .transpose()?;

        Ok(harmonia_store_derivation::derivation::DerivationT {
            name,
            outputs,
            inputs,
            platform: ByteString::from(d.platform),
            builder: ByteString::from(d.builder),
            args: d.args.into_iter().map(ByteString::from).collect(),
            env: d
                .env
                .into_iter()
                .map(|(k, v)| (ByteString::from(k), ByteString::from(v)))
                .collect(),
            structured_attrs,
        })
    }
}

// -- UnkeyedValidPathInfo --

impl From<&harmonia_store_path_info::UnkeyedValidPathInfo> for UnkeyedValidPathInfo {
    fn from(v: &harmonia_store_path_info::UnkeyedValidPathInfo) -> Self {
        let nar_hash: harmonia_utils_hash::Hash = v.nar_hash.into();
        Self {
            deriver: v.deriver.as_ref().map(ProtoStorePath::from),
            nar_hash: Some(nix::store::v1::Hash::from(&nar_hash)),
            references: v.references.iter().map(ProtoStorePath::from).collect(),
            registration_time: v.registration_time.map(|t| t.get()),
            nar_size: v.nar_size,
            ultimate: v.ultimate,
            signatures: v
                .signatures
                .iter()
                .map(nix::store::v1::Signature::from)
                .collect(),
            ca: v.ca.as_ref().map(nix::store::v1::ContentAddress::from),
            store_dir: v.store_dir.to_string(),
        }
    }
}

impl TryFrom<UnkeyedValidPathInfo> for harmonia_store_path_info::UnkeyedValidPathInfo {
    type Error = NarInfoConvertError;

    fn try_from(v: UnkeyedValidPathInfo) -> Result<Self, Self::Error> {
        let raw_hash: harmonia_utils_hash::Hash = v
            .nar_hash
            .ok_or(NarInfoConvertError("missing nar_hash"))?
            .try_into()
            .map_err(|_| NarInfoConvertError("invalid nar_hash"))?;
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
                .filter_map(|s| harmonia_utils_signature::Signature::try_from(s).ok())
                .collect(),
            ca: v
                .ca
                .map(harmonia_store_content_address::ContentAddress::try_from)
                .transpose()
                .map_err(|_| NarInfoConvertError("invalid ca"))?,
            store_dir: harmonia_store_path::StoreDir::new(&v.store_dir).unwrap_or_default(),
        })
    }
}

// -- ValidPathInfo (keyed) --

impl
    From<(
        &harmonia_store_path::StorePath,
        &harmonia_store_path_info::UnkeyedValidPathInfo,
    )> for ValidPathInfo
{
    fn from(
        (path, info): (
            &harmonia_store_path::StorePath,
            &harmonia_store_path_info::UnkeyedValidPathInfo,
        ),
    ) -> Self {
        Self {
            path: Some(ProtoStorePath::from(path)),
            info: Some(UnkeyedValidPathInfo::from(info)),
        }
    }
}

// -- UnkeyedNarInfo --

impl From<&harmonia_store_nar_info::UnkeyedNarInfo> for UnkeyedNarInfo {
    fn from(n: &harmonia_store_nar_info::UnkeyedNarInfo) -> Self {
        Self {
            info: Some(UnkeyedValidPathInfo::from(&n.info)),
            url: n.url.clone().unwrap_or_default(),
            compression: n.compression.clone().unwrap_or_default(),
            download_hash: n.download_hash.as_ref().map(nix::store::v1::Hash::from),
            download_size: n.download_size,
        }
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
            download_hash: n
                .download_hash
                .map(harmonia_utils_hash::Hash::try_from)
                .transpose()
                .map_err(|_| NarInfoConvertError("invalid download_hash"))?,
            download_size: n.download_size,
        })
    }
}

// -- NarInfo --

impl From<&harmonia_store_nar_info::NarInfo> for NarInfo {
    fn from(n: &harmonia_store_nar_info::NarInfo) -> Self {
        Self {
            path: Some(ProtoStorePath::from(n.path.clone())),
            info: Some(UnkeyedNarInfo::from(&n.info)),
        }
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

// -- BuildProduct --

impl From<nix_support::BuildProduct> for BuildProduct {
    fn from(p: nix_support::BuildProduct) -> Self {
        Self {
            path: Some((&p.path).into()),
            default_path: p.default_path,
            r#type: p.r#type,
            subtype: p.subtype,
            name: p.name,
            is_regular: p.is_regular,
            sha256hash: p.sha256hash.map(|h| {
                harmonia_utils_hash::fmt::Bare::<harmonia_utils_hash::fmt::Base16<_>>::from(h)
                    .to_string()
            }),
            file_size: p.file_size,
        }
    }
}

impl TryFrom<BuildProduct> for nix_support::BuildProduct {
    type Error = &'static str;

    fn try_from(p: BuildProduct) -> Result<Self, Self::Error> {
        let path: store_path_utils::RelativeStorePath =
            p.path.ok_or("BuildProduct missing path")?.try_into()?;
        Ok(Self {
            path,
            default_path: p.default_path,
            r#type: p.r#type,
            subtype: p.subtype,
            name: p.name,
            is_regular: p.is_regular,
            sha256hash: p.sha256hash.as_deref().and_then(|s| {
                s.parse::<harmonia_utils_hash::fmt::Bare<
                    harmonia_utils_hash::fmt::Base16<harmonia_utils_hash::Sha256>,
                >>()
                .ok()
                .map(Into::into)
            }),
            file_size: p.file_size,
        })
    }
}

// -- BuildMetric --

impl From<nix_support::BuildMetric> for BuildMetric {
    fn from(m: nix_support::BuildMetric) -> Self {
        Self {
            unit: m.unit,
            value: m.value,
        }
    }
}

impl From<BuildMetric> for nix_support::BuildMetric {
    fn from(m: BuildMetric) -> Self {
        Self {
            unit: m.unit,
            value: m.value,
        }
    }
}

// -- NixSupport --

impl From<nix_support::NixSupport> for NixSupport {
    fn from(ns: nix_support::NixSupport) -> Self {
        Self {
            failed: ns.failed,
            hydra_release_name: ns.hydra_release_name,
            metrics: ns.metrics.into_iter().map(|(k, v)| (k, v.into())).collect(),
            products: ns.products.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<NixSupport> for nix_support::NixSupport {
    fn from(ns: NixSupport) -> Self {
        Self {
            failed: ns.failed,
            hydra_release_name: ns.hydra_release_name,
            metrics: ns.metrics.into_iter().map(|(k, v)| (k, v.into())).collect(),
            products: ns
                .products
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<_, _>>()
                .unwrap_or_default(),
        }
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

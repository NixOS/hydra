use std::collections::BTreeMap;

pub use harmonia_store_core::realisation::{DrvOutput, Realisation};
pub use harmonia_store_core::signature::Signature;

#[cxx::bridge(namespace = "nix_utils")]
mod ffi {
    #![allow(unreachable_pub, unused_qualifications)]

    #[derive(Debug)]
    struct FfiDrvOutput {
        drv_hash: String,
        output_name: String,
    }

    #[derive(Debug)]
    struct DrvOutputPathTuple {
        id: FfiDrvOutput,
        path: String,
    }

    #[derive(Debug)]
    struct SharedRealisation {
        id: FfiDrvOutput,
        out_path: String,
        signatures: Vec<String>,
        dependent_realisations: Vec<DrvOutputPathTuple>,
    }

    unsafe extern "C++" {
        include!("nix-utils/include/realisation.h");

        type StoreWrapper = crate::ffi::StoreWrapper;
        type InternalRealisation;

        fn as_json(self: &InternalRealisation) -> String;
        fn to_rust(self: &InternalRealisation, store: &StoreWrapper) -> Result<SharedRealisation>;
        fn get_drv_output(self: &InternalRealisation) -> FfiDrvOutput;

        fn fingerprint(self: &InternalRealisation) -> String;
        fn sign(self: Pin<&mut InternalRealisation>, secret_key: &str) -> Result<()>;
        fn clear_signatures(self: Pin<&mut InternalRealisation>);

        fn write_to_disk_cache(self: &InternalRealisation, store: &StoreWrapper) -> Result<()>;

        fn query_raw_realisation(
            store: &StoreWrapper,
            output_id: &str,
        ) -> Result<SharedPtr<InternalRealisation>>;

        fn parse_realisation(json_string: &str) -> Result<SharedPtr<InternalRealisation>>;
    }
}

fn parse_drv_output(ffi: ffi::FfiDrvOutput) -> DrvOutput {
    let s = format!("{}!{}", ffi.drv_hash, ffi.output_name);
    s.parse()
        .unwrap_or_else(|e| panic!("invalid DrvOutput from FFI '{s}': {e}"))
}

#[derive(Clone)]
#[allow(missing_debug_implementations)]
pub struct FfiRealisation {
    inner: cxx::SharedPtr<ffi::InternalRealisation>,
}
unsafe impl Send for FfiRealisation {}
unsafe impl Sync for FfiRealisation {}

impl FfiRealisation {
    #[must_use]
    pub fn as_json(&self) -> String {
        self.inner.as_json()
    }

    pub fn as_rust(&self, store: &crate::BaseStoreImpl) -> Result<Realisation, crate::Error> {
        Ok(self.inner.to_rust(store.wrapper.as_raw())?.into())
    }

    #[must_use]
    pub fn get_id(&self) -> DrvOutput {
        parse_drv_output(self.inner.get_drv_output())
    }

    #[must_use]
    pub fn fingerprint(&self) -> String {
        self.inner.fingerprint()
    }

    pub fn sign(&mut self, secret_key: &str) -> Result<(), crate::Error> {
        unsafe { self.inner.pin_mut_unchecked() }.sign(secret_key)?;
        Ok(())
    }

    pub fn clear_signatures(&mut self) {
        unsafe { self.inner.pin_mut_unchecked() }.clear_signatures();
    }

    pub fn write_to_disk_cache(&self, store: &crate::BaseStoreImpl) -> Result<(), crate::Error> {
        self.inner.write_to_disk_cache(store.wrapper.as_raw())?;
        Ok(())
    }
}

impl From<ffi::SharedRealisation> for Realisation {
    fn from(value: ffi::SharedRealisation) -> Self {
        Self {
            id: parse_drv_output(value.id),
            out_path: crate::parse_store_path(&value.out_path),
            signatures: value
                .signatures
                .into_iter()
                .filter_map(|s| s.parse::<Signature>().ok())
                .collect(),
            dependent_realisations: value
                .dependent_realisations
                .into_iter()
                .map(|v| (parse_drv_output(v.id), crate::parse_store_path(&v.path)))
                .collect::<BTreeMap<_, _>>(),
        }
    }
}

pub trait RealisationOperations {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error>;
    fn parse_realisation(&self, json_string: &str) -> Result<FfiRealisation, crate::Error>;
}

impl RealisationOperations for crate::BaseStoreImpl {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error> {
        Ok(FfiRealisation {
            inner: ffi::query_raw_realisation(
                self.wrapper.as_raw(),
                &id.to_string(),
            )?,
        })
    }

    fn parse_realisation(&self, json_string: &str) -> Result<FfiRealisation, crate::Error> {
        Ok(FfiRealisation {
            inner: ffi::parse_realisation(json_string)?,
        })
    }
}

impl RealisationOperations for crate::LocalStore {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error> {
        self.base.query_raw_realisation(id)
    }

    fn parse_realisation(&self, json_string: &str) -> Result<FfiRealisation, crate::Error> {
        self.base.parse_realisation(json_string)
    }
}

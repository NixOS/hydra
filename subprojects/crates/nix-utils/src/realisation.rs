pub use harmonia_store_core::{
    realisation::{
        DrvOutput,
        Realisation,
    },
    signature::Signature,
};

#[cxx::bridge(namespace = "nix_utils")]
mod ffi {
    #![allow(unreachable_pub, unused_qualifications)]

    unsafe extern "C++" {
        include!("nix-utils/include/realisation.h");

        type StoreWrapper = crate::ffi::StoreWrapper;
        type InternalRealisation;

        fn as_json(self: &InternalRealisation) -> String;

        fn query_raw_realisation(
            store: &StoreWrapper,
            output_id: &str,
        ) -> Result<SharedPtr<InternalRealisation>>;
    }
}

#[derive(Clone)]
#[allow(missing_debug_implementations)]
pub struct FfiRealisation {
    inner: cxx::SharedPtr<ffi::InternalRealisation>,
}
unsafe impl Send for FfiRealisation {}
unsafe impl Sync for FfiRealisation {}

impl FfiRealisation {
    pub fn as_rust(&self) -> Result<Realisation, crate::Error> {
        let json = self.inner.as_json();
        Ok(serde_json::from_str(&json)?)
    }
}

pub trait RealisationOperations {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error>;
}

impl RealisationOperations for crate::BaseStoreImpl {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error> {
        Ok(FfiRealisation {
            inner: ffi::query_raw_realisation(self.wrapper.as_raw(), &id.to_string())?,
        })
    }
}

impl RealisationOperations for crate::LocalStore {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error> {
        self.base.query_raw_realisation(id)
    }
}

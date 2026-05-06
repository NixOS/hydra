pub use harmonia_store_core::realisation::{DrvOutput, Realisation, UnkeyedRealisation};
pub use harmonia_store_core::signature::Signature;

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

        fn register_drv_output(store: &StoreWrapper, json: &str) -> Result<()>;
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
    /// Query a realisation from the store. Currently unused — realisations
    /// are constructed from buildstep data instead — but kept for potential
    /// future use.
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error>;
    fn register_drv_output(&self, realisation: &Realisation) -> Result<(), crate::Error>;
}

impl RealisationOperations for crate::BaseStoreImpl {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error> {
        Ok(FfiRealisation {
            inner: ffi::query_raw_realisation(self.wrapper.as_raw(), &id.to_string())?,
        })
    }

    fn register_drv_output(&self, realisation: &Realisation) -> Result<(), crate::Error> {
        let json = serde_json::to_string(realisation)?;
        Ok(ffi::register_drv_output(self.wrapper.as_raw(), &json)?)
    }
}

impl RealisationOperations for crate::LocalStore {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error> {
        self.base.query_raw_realisation(id)
    }

    fn register_drv_output(&self, realisation: &Realisation) -> Result<(), crate::Error> {
        self.base.register_drv_output(realisation)
    }
}

impl RealisationOperations for crate::RemoteStore {
    fn query_raw_realisation(&self, id: &DrvOutput) -> Result<FfiRealisation, crate::Error> {
        self.base.query_raw_realisation(id)
    }

    fn register_drv_output(&self, realisation: &Realisation) -> Result<(), crate::Error> {
        self.base.register_drv_output(realisation)
    }
}

pub use harmonia_store_core::realisation::{DrvOutput, Realisation};
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
    }
}

pub trait RealisationOperations {
    fn query_realisation(&self, id: &DrvOutput) -> Result<Realisation, crate::Error>;
}

impl RealisationOperations for crate::BaseStoreImpl {
    fn query_realisation(&self, id: &DrvOutput) -> Result<Realisation, crate::Error> {
        let raw = ffi::query_raw_realisation(self.wrapper.as_raw(), &id.to_string())?;
        let json = raw.as_json();
        Ok(serde_json::from_str(&json)?)
    }
}

impl RealisationOperations for crate::LocalStore {
    fn query_realisation(&self, id: &DrvOutput) -> Result<Realisation, crate::Error> {
        self.base.query_realisation(id)
    }
}

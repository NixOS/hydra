use hashbrown::HashMap;

#[cxx::bridge(namespace = "nix_utils")]
mod ffi {
    #[derive(Debug)]
    struct DrvOutput {
        drv_hash: String,
        output_name: String,
    }

    #[derive(Debug)]
    struct DrvOutputPathTuple {
        id: DrvOutput,
        path: String,
    }

    #[derive(Debug)]
    struct SharedRealisation {
        id: DrvOutput,
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
        fn get_drv_output(self: &InternalRealisation) -> DrvOutput;

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

#[derive(Clone)]
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
        Ok(self.inner.to_rust(&store.wrapper)?.into())
    }

    #[must_use]
    pub fn get_id(&self) -> DrvOutput {
        self.inner.get_drv_output().into()
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
        self.inner.write_to_disk_cache(&store.wrapper)?;
        Ok(())
    }
}

#[derive(Debug, Clone, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub struct DrvOutput {
    pub drv_hash: String,
    pub output_name: String,
}

impl From<ffi::DrvOutput> for DrvOutput {
    fn from(value: ffi::DrvOutput) -> Self {
        Self {
            drv_hash: value.drv_hash,
            output_name: value.output_name,
        }
    }
}

impl std::fmt::Display for DrvOutput {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> Result<(), std::fmt::Error> {
        write!(f, "{}!{}", self.drv_hash, self.output_name)
    }
}

#[derive(Debug, Clone)]
pub struct Realisation {
    pub id: DrvOutput,
    pub out_path: crate::StorePath,
    pub signatures: Vec<String>,
    pub dependent_realisations: HashMap<DrvOutput, crate::StorePath>,
}

impl From<ffi::SharedRealisation> for Realisation {
    fn from(value: ffi::SharedRealisation) -> Self {
        Self {
            id: value.id.into(),
            out_path: crate::StorePath::new(&value.out_path),
            signatures: value.signatures,
            dependent_realisations: value
                .dependent_realisations
                .into_iter()
                .map(|v| (v.id.into(), crate::StorePath::new(&v.path)))
                .collect(),
        }
    }
}

pub trait RealisationOperations {
    fn query_raw_realisation(
        &self,
        output_hash: &str,
        output_name: &str,
    ) -> Result<FfiRealisation, crate::Error>;

    fn parse_realisation(&self, json_string: &str) -> Result<FfiRealisation, crate::Error>;
}

impl RealisationOperations for crate::BaseStoreImpl {
    fn query_raw_realisation(
        &self,
        output_hash: &str,
        output_name: &str,
    ) -> Result<FfiRealisation, crate::Error> {
        Ok(FfiRealisation {
            inner: ffi::query_raw_realisation(
                &self.wrapper,
                &format!("{output_hash}!{output_name}"),
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
    fn query_raw_realisation(
        &self,
        output_hash: &str,
        output_name: &str,
    ) -> Result<FfiRealisation, crate::Error> {
        self.base.query_raw_realisation(output_hash, output_name)
    }

    fn parse_realisation(&self, json_string: &str) -> Result<FfiRealisation, crate::Error> {
        self.base.parse_realisation(json_string)
    }
}

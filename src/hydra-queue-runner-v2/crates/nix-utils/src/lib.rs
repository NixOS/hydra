mod drv;

#[derive(thiserror::Error, Debug)]
pub enum Error {
    #[error("std io error: `{0}`")]
    Io(#[from] std::io::Error),

    #[error("tokio join error: `{0}`")]
    TokioJoin(#[from] tokio::task::JoinError),

    #[error("utf8 error: `{0}`")]
    Utf8(#[from] std::str::Utf8Error),

    #[error("Failed to get tokio stdout stream")]
    Stream,

    #[error("regex error: `{0}`")]
    Regex(#[from] regex::Error),

    #[error("Command failed with `{0}`")]
    Exit(std::process::ExitStatus),

    #[error("Exception was thrown `{0}`")]
    Exception(#[from] cxx::Exception),

    #[error("anyhow error: `{0}`")]
    Anyhow(#[from] anyhow::Error),
}

use ahash::AHashMap;
pub use drv::{
    BuildOptions, Derivation, Output as DerivationOutput, query_drv, query_missing_outputs,
    realise_drv, realise_drvs,
};

pub const HASH_LEN: usize = 32;

#[derive(Debug, Clone, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub struct StorePath {
    base_name: String,
}

impl StorePath {
    pub fn new(p: &str) -> Self {
        if let Some(postfix) = p.strip_prefix("/nix/store/") {
            debug_assert!(postfix.len() > HASH_LEN + 1);
            Self {
                base_name: postfix.to_string(),
            }
        } else {
            debug_assert!(p.len() > HASH_LEN + 1);
            Self {
                base_name: p.to_string(),
            }
        }
    }

    pub fn into_base_name(self) -> String {
        self.base_name
    }

    pub fn base_name(&self) -> &str {
        &self.base_name
    }

    pub fn name(&self) -> &str {
        &self.base_name[HASH_LEN + 1..]
    }

    pub fn hash_part(&self) -> &str {
        &self.base_name[..HASH_LEN]
    }

    pub fn is_drv(&self) -> bool {
        self.base_name.ends_with(".drv")
    }

    pub fn get_full_path(&self) -> String {
        format!("/nix/store/{}", self.base_name)
    }
}
impl serde::Serialize for StorePath {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.base_name())
    }
}

impl std::fmt::Display for StorePath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> Result<(), std::fmt::Error> {
        write!(f, "{}", self.base_name)
    }
}

#[tracing::instrument(skip(path))]
pub async fn check_if_storepath_exists(path: &StorePath) -> bool {
    tokio::fs::try_exists(&path.get_full_path())
        .await
        .unwrap_or_default()
}

pub fn validate_statuscode(status: std::process::ExitStatus) -> Result<(), Error> {
    if status.success() {
        Ok(())
    } else {
        Err(Error::Exit(status))
    }
}

pub fn add_root(root_dir: &std::path::Path, store_path: &StorePath) {
    let path = root_dir.join(store_path.base_name());
    // force create symlink
    if path.exists() {
        let _ = std::fs::remove_file(&path);
    }
    if !path.exists() {
        let _ = std::os::unix::fs::symlink(store_path.get_full_path(), path);
    }
}

#[cxx::bridge(namespace = "nix_utils")]
mod ffi {
    #[derive(Debug)]
    struct InternalPathInfo {
        deriver: String,
        nar_hash: String,
        registration_time: i64,
        nar_size: u64,
        refs: Vec<String>,
        sigs: Vec<String>,
        ca: String,
    }

    #[derive(Debug)]
    struct StoreStats {
        nar_info_read: u64,
        nar_info_read_averted: u64,
        nar_info_missing: u64,
        nar_info_write: u64,
        path_info_cache_size: u64,
        nar_read: u64,
        nar_read_bytes: u64,
        nar_read_compressed_bytes: u64,
        nar_write: u64,
        nar_write_averted: u64,
        nar_write_bytes: u64,
        nar_write_compressed_bytes: u64,
        nar_write_compression_time_ms: u64,
    }

    #[derive(Debug)]
    struct S3Stats {
        put: u64,
        put_bytes: u64,
        put_time_ms: u64,
        get: u64,
        get_bytes: u64,
        get_time_ms: u64,
        head: u64,
    }

    unsafe extern "C++" {
        include!("nix-utils/include/nix.h");

        type StoreWrapper;

        fn init(uri: &str) -> SharedPtr<StoreWrapper>;

        fn get_nix_prefix() -> String;
        fn get_store_dir() -> String;
        fn get_log_dir() -> String;
        fn get_state_dir() -> String;
        fn get_this_system() -> String;
        fn get_extra_platforms() -> Vec<String>;
        fn get_system_features() -> Vec<String>;
        fn get_use_cgroups() -> bool;
        fn set_verbosity(level: i32);

        fn is_valid_path(store: &StoreWrapper, path: &str) -> Result<bool>;
        fn query_path_info(store: &StoreWrapper, path: &str) -> Result<InternalPathInfo>;
        fn compute_closure_size(store: &StoreWrapper, path: &str) -> Result<u64>;
        fn clear_path_info_cache(store: &StoreWrapper) -> Result<()>;
        fn compute_fs_closure(
            store: &StoreWrapper,
            path: &str,
            flip_direction: bool,
            include_outputs: bool,
            include_derivers: bool,
        ) -> Result<Vec<String>>;
        fn compute_fs_closures(
            store: &StoreWrapper,
            paths: &[&str],
            flip_direction: bool,
            include_outputs: bool,
            include_derivers: bool,
            toposort: bool,
        ) -> Result<Vec<String>>;
        fn upsert_file(store: &StoreWrapper, path: &str, data: &str, mime_type: &str)
        -> Result<()>;
        fn get_store_stats(store: &StoreWrapper) -> Result<StoreStats>;
        fn get_s3_stats(store: &StoreWrapper) -> Result<S3Stats>;
        fn copy_paths(
            src_store: &StoreWrapper,
            dst_store: &StoreWrapper,
            paths: &[&str],
            repair: bool,
            check_sigs: bool,
            substitute: bool,
        ) -> Result<()>;

        fn import_paths(
            store: &StoreWrapper,
            check_sigs: bool,
            runtime: usize,
            reader: usize,
            callback: unsafe extern "C" fn(
                data: &mut [u8],
                runtime: usize,
                reader: usize,
                user_data: usize,
            ) -> usize,
            user_data: usize,
        ) -> Result<()>;
        fn import_paths_with_fd(store: &StoreWrapper, check_sigs: bool, fd: i32) -> Result<()>;
        fn export_paths(
            store: &StoreWrapper,
            paths: &[&str],
            callback: unsafe extern "C" fn(data: &[u8], user_data: usize) -> bool,
            user_data: usize,
        ) -> Result<()>;

        fn try_resolve_drv(store: &StoreWrapper, path: &str) -> Result<String>;
    }
}

pub use ffi::{S3Stats, StoreStats};

#[inline]
#[must_use]
pub fn get_nix_prefix() -> String {
    ffi::get_nix_prefix()
}

#[inline]
#[must_use]
pub fn get_store_dir() -> String {
    ffi::get_store_dir()
}

#[inline]
#[must_use]
pub fn get_log_dir() -> String {
    ffi::get_log_dir()
}

#[inline]
#[must_use]
pub fn get_state_dir() -> String {
    ffi::get_state_dir()
}

#[inline]
#[must_use]
pub fn get_this_system() -> String {
    ffi::get_this_system()
}

#[inline]
#[must_use]
pub fn get_extra_platforms() -> Vec<String> {
    ffi::get_extra_platforms()
}

#[inline]
#[must_use]
pub fn get_system_features() -> Vec<String> {
    ffi::get_system_features()
}

#[inline]
#[must_use]
pub fn get_use_cgroups() -> bool {
    ffi::get_use_cgroups()
}

#[inline]
/// Set the loglevel.
pub fn set_verbosity(level: i32) {
    ffi::set_verbosity(level);
}

pub(crate) async fn asyncify<F, T>(f: F) -> Result<T, Error>
where
    F: FnOnce() -> Result<T, cxx::Exception> + Send + 'static,
    T: Send + 'static,
{
    match tokio::task::spawn_blocking(f).await {
        Ok(res) => Ok(res?),
        Err(_) => Err(std::io::Error::new(
            std::io::ErrorKind::Other,
            "background task failed",
        ))?,
    }
}

#[inline]
pub async fn copy_paths(
    src: &BaseStoreImpl,
    dst: &BaseStoreImpl,
    paths: &[StorePath],
    repair: bool,
    check_sigs: bool,
    substitute: bool,
) -> Result<(), Error> {
    let paths = paths.iter().map(|v| v.get_full_path()).collect::<Vec<_>>();

    let src = src.wrapper.clone();
    let dst = dst.wrapper.clone();

    asyncify(move || {
        let slice = paths.iter().map(|v| v.as_str()).collect::<Vec<_>>();
        ffi::copy_paths(&src, &dst, &slice, repair, check_sigs, substitute)
    })
    .await
}

#[derive(Debug)]
pub struct PathInfo {
    pub deriver: Option<StorePath>,
    pub nar_hash: String,
    pub registration_time: i64,
    pub nar_size: u64,
    pub refs: Vec<StorePath>,
    pub sigs: Vec<String>,
    pub ca: Option<String>,
}

impl From<crate::ffi::InternalPathInfo> for PathInfo {
    fn from(val: crate::ffi::InternalPathInfo) -> Self {
        Self {
            deriver: if val.deriver.is_empty() {
                None
            } else {
                Some(StorePath::new(&val.deriver))
            },
            nar_hash: val.nar_hash,
            registration_time: val.registration_time,
            nar_size: val.nar_size,
            refs: val.refs.iter().map(|v| StorePath::new(v)).collect(),
            sigs: val.sigs,
            ca: if val.ca.is_empty() {
                None
            } else {
                Some(val.ca)
            },
        }
    }
}

pub trait BaseStore {
    #[must_use]
    /// Check whether a path is valid.
    fn is_valid_path(&self, path: StorePath) -> impl std::future::Future<Output = bool>;

    fn query_path_info(&self, path: &StorePath) -> Option<PathInfo>;
    fn query_path_infos(&self, paths: &[&StorePath]) -> AHashMap<StorePath, PathInfo>;
    fn compute_closure_size(&self, path: &StorePath) -> u64;

    fn clear_path_info_cache(&self);

    fn compute_fs_closure(
        &self,
        path: &str,
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
    ) -> Result<Vec<String>, cxx::Exception>;

    fn compute_fs_closures(
        &self,
        paths: &[&str],
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
        toposort: bool,
    ) -> Result<Vec<StorePath>, cxx::Exception>;

    fn query_requisites(
        &self,
        drvs: Vec<StorePath>,
        include_outputs: bool,
    ) -> impl std::future::Future<Output = Result<Vec<StorePath>, crate::Error>>;

    fn get_store_stats(&self) -> Result<crate::ffi::StoreStats, cxx::Exception>;

    /// Import paths from nar
    fn import_paths<S>(
        &self,
        stream: S,
        check_sigs: bool,
    ) -> impl std::future::Future<Output = Result<(), Error>>
    where
        S: tokio_stream::Stream<Item = Result<bytes::Bytes, std::io::Error>>
            + Send
            + Unpin
            + 'static;

    /// Import paths from nar
    fn import_paths_with_fd<Fd>(&self, fd: Fd, check_sigs: bool) -> Result<(), cxx::Exception>
    where
        Fd: std::os::fd::AsFd + std::os::fd::AsRawFd;

    /// Export a store path in NAR format. The data is passed in chunks to callback
    fn export_paths<F>(&self, paths: &[StorePath], callback: F) -> Result<(), cxx::Exception>
    where
        F: FnMut(&[u8]) -> bool;

    fn try_resolve_drv(&self, path: &StorePath) -> Option<StorePath>;
}

unsafe impl Send for crate::ffi::StoreWrapper {}
unsafe impl Sync for crate::ffi::StoreWrapper {}

#[derive(Clone)]
pub struct BaseStoreImpl {
    wrapper: cxx::SharedPtr<crate::ffi::StoreWrapper>,
}

impl BaseStoreImpl {
    fn new(store: cxx::SharedPtr<crate::ffi::StoreWrapper>) -> Self {
        Self { wrapper: store }
    }
}

fn import_paths_trampoline<F, S, E>(
    data: &mut [u8],
    runtime: usize,
    reader: usize,
    userdata: usize,
) -> usize
where
    F: FnMut(
        &tokio::runtime::Runtime,
        &mut Box<tokio_util::io::StreamReader<S, bytes::Bytes>>,
        &mut [u8],
    ) -> usize,
    S: futures::stream::Stream<Item = Result<bytes::Bytes, E>>,
    E: Into<std::io::Error>,
{
    let runtime =
        unsafe { &*(runtime as *mut std::ffi::c_void).cast::<Box<tokio::runtime::Runtime>>() };
    let reader = unsafe {
        &mut *(reader as *mut std::ffi::c_void)
            .cast::<Box<tokio_util::io::StreamReader<S, bytes::Bytes>>>()
    };
    let closure = unsafe { &mut *(userdata as *mut std::ffi::c_void).cast::<F>() };
    closure(runtime, reader, data)
}

fn export_paths_trampoline<F>(data: &[u8], userdata: usize) -> bool
where
    F: FnMut(&[u8]) -> bool,
{
    let closure = unsafe { &mut *(userdata as *mut std::ffi::c_void).cast::<F>() };
    closure(data)
}

impl BaseStore for BaseStoreImpl {
    #[inline]
    async fn is_valid_path(&self, path: StorePath) -> bool {
        let store = self.wrapper.clone();
        asyncify(move || ffi::is_valid_path(&store, &path.get_full_path()))
            .await
            .unwrap_or(false)
    }

    #[inline]
    fn query_path_info(&self, path: &StorePath) -> Option<PathInfo> {
        ffi::query_path_info(&self.wrapper, &path.get_full_path())
            .ok()
            .map(Into::into)
    }

    #[inline]
    fn query_path_infos(&self, paths: &[&StorePath]) -> AHashMap<StorePath, PathInfo> {
        let mut res = AHashMap::new();
        for p in paths {
            if let Some(info) = self.query_path_info(p) {
                res.insert((*p).to_owned(), info);
            }
        }
        res
    }

    #[inline]
    fn compute_closure_size(&self, path: &StorePath) -> u64 {
        ffi::compute_closure_size(&self.wrapper, &path.get_full_path()).unwrap_or_default()
    }

    #[inline]
    fn clear_path_info_cache(&self) {
        let _ = ffi::clear_path_info_cache(&self.wrapper);
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    fn compute_fs_closure(
        &self,
        path: &str,
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
    ) -> Result<Vec<String>, cxx::Exception> {
        ffi::compute_fs_closure(
            &self.wrapper,
            path,
            flip_direction,
            include_outputs,
            include_derivers,
        )
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    fn compute_fs_closures(
        &self,
        paths: &[&str],
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
        toposort: bool,
    ) -> Result<Vec<StorePath>, cxx::Exception> {
        Ok(ffi::compute_fs_closures(
            &self.wrapper,
            paths,
            flip_direction,
            include_outputs,
            include_derivers,
            toposort,
        )?
        .into_iter()
        .map(|v| StorePath::new(&v))
        .collect())
    }

    async fn query_requisites(
        &self,
        drvs: Vec<StorePath>,
        include_outputs: bool,
    ) -> Result<Vec<StorePath>, Error> {
        let paths = drvs.iter().map(|v| v.get_full_path()).collect::<Vec<_>>();
        let slice = paths.iter().map(|v| v.as_str()).collect::<Vec<_>>();

        let mut out = self.compute_fs_closures(&slice, false, include_outputs, false, true)?;
        out.reverse();
        Ok(out)
    }

    fn get_store_stats(&self) -> Result<crate::ffi::StoreStats, cxx::Exception> {
        ffi::get_store_stats(&self.wrapper)
    }

    #[inline]
    #[tracing::instrument(skip(self, stream), err)]
    async fn import_paths<S>(&self, stream: S, check_sigs: bool) -> Result<(), Error>
    where
        S: tokio_stream::Stream<Item = Result<bytes::Bytes, std::io::Error>>
            + Send
            + Unpin
            + 'static,
    {
        use tokio::io::AsyncReadExt as _;

        let callback = |runtime: &tokio::runtime::Runtime,
                        reader: &mut Box<tokio_util::io::StreamReader<_, bytes::Bytes>>,
                        data: &mut [u8]| {
            runtime.block_on(async { reader.read(data).await.unwrap_or(0) })
        };

        let reader = Box::new(tokio_util::io::StreamReader::new(stream));
        let store = self.clone();
        tokio::task::spawn_blocking(move || {
            store.import_paths_with_cb(callback, reader, check_sigs)
        })
        .await??;
        Ok(())
    }

    #[inline]
    #[tracing::instrument(skip(self, fd), err)]
    fn import_paths_with_fd<Fd>(&self, fd: Fd, check_sigs: bool) -> Result<(), cxx::Exception>
    where
        Fd: std::os::fd::AsFd + std::os::fd::AsRawFd,
    {
        ffi::import_paths_with_fd(&self.wrapper, check_sigs, fd.as_raw_fd())
    }

    #[inline]
    #[tracing::instrument(skip(self, paths, callback), err)]
    fn export_paths<F>(&self, paths: &[StorePath], callback: F) -> Result<(), cxx::Exception>
    where
        F: FnMut(&[u8]) -> bool,
    {
        let paths = paths.iter().map(|v| v.get_full_path()).collect::<Vec<_>>();
        let slice = paths.iter().map(|v| v.as_str()).collect::<Vec<_>>();
        ffi::export_paths(
            &self.wrapper,
            &slice,
            export_paths_trampoline::<F>,
            std::ptr::addr_of!(callback).cast::<std::ffi::c_void>() as usize,
        )
    }
    #[inline]
    fn try_resolve_drv(&self, path: &StorePath) -> Option<StorePath> {
        let v = ffi::try_resolve_drv(&self.wrapper, &path.get_full_path()).ok()?;
        v.is_empty().then_some(v).map(|v| StorePath::new(&v))
    }
}

impl BaseStoreImpl {
    #[inline]
    #[tracing::instrument(skip(self, callback, reader), err)]
    fn import_paths_with_cb<F, S, E>(
        &self,
        callback: F,
        reader: Box<tokio_util::io::StreamReader<S, bytes::Bytes>>,
        check_sigs: bool,
    ) -> Result<(), cxx::Exception>
    where
        F: FnMut(
            &tokio::runtime::Runtime,
            &mut Box<tokio_util::io::StreamReader<S, bytes::Bytes>>,
            &mut [u8],
        ) -> usize,
        S: futures::stream::Stream<Item = Result<bytes::Bytes, E>>,
        E: Into<std::io::Error>,
    {
        let runtime = Box::new(tokio::runtime::Runtime::new().unwrap());
        ffi::import_paths(
            &self.wrapper,
            check_sigs,
            std::ptr::addr_of!(runtime).cast::<std::ffi::c_void>() as usize,
            std::ptr::addr_of!(reader).cast::<std::ffi::c_void>() as usize,
            import_paths_trampoline::<F, S, E>,
            std::ptr::addr_of!(callback).cast::<std::ffi::c_void>() as usize,
        )?;
        drop(reader);
        drop(runtime);
        Ok(())
    }
}

#[derive(Clone)]
pub struct LocalStore {
    base: BaseStoreImpl,
}

impl LocalStore {
    #[inline]
    /// Initialise a new store
    pub fn init() -> Self {
        Self {
            base: BaseStoreImpl::new(ffi::init("")),
        }
    }

    pub fn as_base_store(&self) -> &BaseStoreImpl {
        &self.base
    }
}

impl BaseStore for LocalStore {
    #[inline]
    async fn is_valid_path(&self, path: StorePath) -> bool {
        self.base.is_valid_path(path).await
    }

    #[inline]
    fn query_path_info(&self, path: &StorePath) -> Option<PathInfo> {
        self.base.query_path_info(path)
    }

    #[inline]
    fn query_path_infos(&self, paths: &[&StorePath]) -> AHashMap<StorePath, PathInfo> {
        self.base.query_path_infos(paths)
    }

    #[inline]
    fn compute_closure_size(&self, path: &StorePath) -> u64 {
        self.base.compute_closure_size(path)
    }

    #[inline]
    fn clear_path_info_cache(&self) {
        self.base.clear_path_info_cache();
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    fn compute_fs_closure(
        &self,
        path: &str,
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
    ) -> Result<Vec<String>, cxx::Exception> {
        self.base
            .compute_fs_closure(path, flip_direction, include_outputs, include_derivers)
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    fn compute_fs_closures(
        &self,
        paths: &[&str],
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
        toposort: bool,
    ) -> Result<Vec<StorePath>, cxx::Exception> {
        self.base.compute_fs_closures(
            paths,
            flip_direction,
            include_outputs,
            include_derivers,
            toposort,
        )
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    async fn query_requisites(
        &self,
        drvs: Vec<StorePath>,
        include_outputs: bool,
    ) -> Result<Vec<StorePath>, Error> {
        self.base.query_requisites(drvs, include_outputs).await
    }

    #[inline]
    fn get_store_stats(&self) -> Result<crate::ffi::StoreStats, cxx::Exception> {
        self.base.get_store_stats()
    }

    #[inline]
    #[tracing::instrument(skip(self, stream), err)]
    async fn import_paths<S>(&self, stream: S, check_sigs: bool) -> Result<(), Error>
    where
        S: tokio_stream::Stream<Item = Result<bytes::Bytes, std::io::Error>>
            + Send
            + Unpin
            + 'static,
    {
        self.base.import_paths::<S>(stream, check_sigs).await
    }

    #[inline]
    #[tracing::instrument(skip(self, fd), err)]
    fn import_paths_with_fd<Fd>(&self, fd: Fd, check_sigs: bool) -> Result<(), cxx::Exception>
    where
        Fd: std::os::fd::AsFd + std::os::fd::AsRawFd,
    {
        self.base.import_paths_with_fd(fd, check_sigs)
    }

    #[inline]
    #[tracing::instrument(skip(self, paths, callback), err)]
    fn export_paths<F>(&self, paths: &[StorePath], callback: F) -> Result<(), cxx::Exception>
    where
        F: FnMut(&[u8]) -> bool,
    {
        self.base.export_paths(paths, callback)
    }

    #[inline]
    fn try_resolve_drv(&self, path: &StorePath) -> Option<StorePath> {
        self.base.try_resolve_drv(path)
    }
}

#[derive(Clone)]
pub struct RemoteStore {
    base: BaseStoreImpl,

    pub uri: String,
    pub base_uri: String,
}

impl RemoteStore {
    #[inline]
    /// Initialise a new store with uri
    pub fn init(uri: &str) -> Self {
        let base_uri = url::Url::parse(uri)
            .ok()
            .and_then(|v| v.host_str().map(ToOwned::to_owned))
            .unwrap_or_default();

        Self {
            base: BaseStoreImpl::new(ffi::init(uri)),
            uri: uri.into(),
            base_uri,
        }
    }

    pub fn as_base_store(&self) -> &BaseStoreImpl {
        &self.base
    }

    #[inline]
    pub async fn upsert_file(
        &self,
        path: String,
        local_path: std::path::PathBuf,
        mime_type: &'static str,
    ) -> Result<(), Error> {
        let store = self.base.wrapper.clone();
        asyncify(move || {
            if let Ok(data) = std::fs::read_to_string(local_path) {
                ffi::upsert_file(&store, &path, &data, mime_type)?
            }
            Ok(())
        })
        .await
    }

    #[inline]
    pub fn get_s3_stats(&self) -> Result<crate::ffi::S3Stats, cxx::Exception> {
        ffi::get_s3_stats(&self.base.wrapper)
    }

    #[tracing::instrument(skip(self, paths))]
    pub async fn query_missing_paths(&self, paths: Vec<StorePath>) -> Vec<StorePath> {
        use futures::stream::StreamExt as _;

        tokio_stream::iter(paths)
            .map(|p| async move {
                if !self.is_valid_path(p.clone()).await {
                    Some(p)
                } else {
                    None
                }
            })
            .buffered(50)
            .filter_map(|p| async { p })
            .collect()
            .await
    }

    #[tracing::instrument(skip(self, outputs))]
    pub async fn query_missing_remote_outputs(
        &self,
        outputs: Vec<DerivationOutput>,
    ) -> Vec<DerivationOutput> {
        use futures::stream::StreamExt as _;

        tokio_stream::iter(outputs)
            .map(|o| async move {
                let Some(path) = &o.path else {
                    return None;
                };
                if !self.is_valid_path(path.clone()).await {
                    Some(o)
                } else {
                    None
                }
            })
            .buffered(50)
            .filter_map(|o| async { o })
            .collect()
            .await
    }
}

impl BaseStore for RemoteStore {
    #[inline]
    async fn is_valid_path(&self, path: StorePath) -> bool {
        self.base.is_valid_path(path).await
    }

    #[inline]
    fn query_path_info(&self, path: &StorePath) -> Option<PathInfo> {
        self.base.query_path_info(path)
    }

    #[inline]
    fn query_path_infos(&self, paths: &[&StorePath]) -> AHashMap<StorePath, PathInfo> {
        self.base.query_path_infos(paths)
    }

    #[inline]
    fn compute_closure_size(&self, path: &StorePath) -> u64 {
        self.base.compute_closure_size(path)
    }

    #[inline]
    fn clear_path_info_cache(&self) {
        self.base.clear_path_info_cache();
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    fn compute_fs_closure(
        &self,
        path: &str,
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
    ) -> Result<Vec<String>, cxx::Exception> {
        self.base
            .compute_fs_closure(path, flip_direction, include_outputs, include_derivers)
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    fn compute_fs_closures(
        &self,
        paths: &[&str],
        flip_direction: bool,
        include_outputs: bool,
        include_derivers: bool,
        toposort: bool,
    ) -> Result<Vec<StorePath>, cxx::Exception> {
        self.base.compute_fs_closures(
            paths,
            flip_direction,
            include_outputs,
            include_derivers,
            toposort,
        )
    }

    #[inline]
    #[tracing::instrument(skip(self), err)]
    async fn query_requisites(
        &self,
        drvs: Vec<StorePath>,
        include_outputs: bool,
    ) -> Result<Vec<StorePath>, Error> {
        self.base.query_requisites(drvs, include_outputs).await
    }

    #[inline]
    fn get_store_stats(&self) -> Result<crate::ffi::StoreStats, cxx::Exception> {
        self.base.get_store_stats()
    }

    #[inline]
    #[tracing::instrument(skip(self, stream), err)]
    async fn import_paths<S>(&self, stream: S, check_sigs: bool) -> Result<(), Error>
    where
        S: tokio_stream::Stream<Item = Result<bytes::Bytes, std::io::Error>>
            + Send
            + Unpin
            + 'static,
    {
        self.base.import_paths::<S>(stream, check_sigs).await
    }

    #[inline]
    #[tracing::instrument(skip(self, fd), err)]
    fn import_paths_with_fd<Fd>(&self, fd: Fd, check_sigs: bool) -> Result<(), cxx::Exception>
    where
        Fd: std::os::fd::AsFd + std::os::fd::AsRawFd,
    {
        self.base.import_paths_with_fd(fd, check_sigs)
    }

    #[inline]
    #[tracing::instrument(skip(self, paths, callback), err)]
    fn export_paths<F>(&self, paths: &[StorePath], callback: F) -> Result<(), cxx::Exception>
    where
        F: FnMut(&[u8]) -> bool,
    {
        self.base.export_paths(paths, callback)
    }

    #[inline]
    fn try_resolve_drv(&self, path: &StorePath) -> Option<StorePath> {
        self.base.try_resolve_drv(path)
    }
}

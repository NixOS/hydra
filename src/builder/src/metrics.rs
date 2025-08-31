use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Default)]
#[allow(clippy::struct_field_names)]
pub struct Metrics {
    pub substituting_path_count: AtomicU64,

    pub uploading_path_count: AtomicU64,
    pub downloading_path_count: AtomicU64,
}

impl Metrics {
    pub fn add_substituting_path(&self, v: u64) {
        self.substituting_path_count.fetch_add(v, Ordering::Relaxed);
    }

    pub fn sub_substituting_path(&self, v: u64) {
        self.substituting_path_count.fetch_sub(v, Ordering::Relaxed);
    }

    #[must_use]
    pub fn get_substituting_path_count(&self) -> u64 {
        self.substituting_path_count.load(Ordering::Relaxed)
    }

    pub fn add_uploading_path(&self, v: u64) {
        self.uploading_path_count.fetch_add(v, Ordering::Relaxed);
    }

    pub fn sub_uploading_path(&self, v: u64) {
        self.uploading_path_count.fetch_sub(v, Ordering::Relaxed);
    }

    #[must_use]
    pub fn get_uploading_path_count(&self) -> u64 {
        self.uploading_path_count.load(Ordering::Relaxed)
    }

    pub fn add_downloading_path(&self, v: u64) {
        self.downloading_path_count.fetch_add(v, Ordering::Relaxed);
    }

    pub fn sub_downloading_path(&self, v: u64) {
        self.downloading_path_count.fetch_sub(v, Ordering::Relaxed);
    }

    #[must_use]
    pub fn get_downloading_path_count(&self) -> u64 {
        self.downloading_path_count.load(Ordering::Relaxed)
    }
}

use harmonia_store_core::store_path::StorePath;

#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadsResponse {
    paths: Vec<StorePath>,
    path_count: usize,
}

impl UploadsResponse {
    #[must_use]
    pub const fn new(paths: Vec<StorePath>) -> Self {
        Self {
            path_count: paths.len(),
            paths,
        }
    }
}

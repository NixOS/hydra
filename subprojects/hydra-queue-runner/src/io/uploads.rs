#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UploadsResponse {
    paths: Vec<nix_utils::StorePath>,
    path_count: usize,
}

impl UploadsResponse {
    #[must_use]
    pub const fn new(paths: Vec<nix_utils::StorePath>) -> Self {
        Self {
            path_count: paths.len(),
            paths,
        }
    }
}

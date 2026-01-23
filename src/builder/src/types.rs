#[allow(clippy::struct_field_names)]
#[derive(Debug, Default, Clone, Copy)]
pub struct BuildTimings {
    pub import_elapsed: std::time::Duration,
    pub build_elapsed: std::time::Duration,
    pub upload_elapsed: std::time::Duration,
}

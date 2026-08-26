#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct ProcessExtra {}

impl ProcessExtra {
    pub(super) fn new() -> Option<Self> {
        Some(Self {})
    }
}

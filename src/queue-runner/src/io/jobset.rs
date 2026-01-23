#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Jobset {
    id: crate::state::JobsetID,
    project_name: String,
    name: String,

    pub seconds: i64,
    pub shares: u32,
}

impl From<std::sync::Arc<crate::state::Jobset>> for Jobset {
    fn from(item: std::sync::Arc<crate::state::Jobset>) -> Self {
        Self {
            id: item.id,
            project_name: item.project_name.clone(),
            name: item.name.clone(),
            seconds: item.get_seconds(),
            shares: item.get_shares(),
        }
    }
}

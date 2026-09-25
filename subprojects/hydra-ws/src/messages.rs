#[derive(Clone, Debug, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type")]
pub enum HydraWsResponse {
    #[serde(rename = "invalidRequest")]
    InvalidRequest { details: String },

    #[serde(rename = "pong")]
    Pong {},

    #[serde(rename = "logsStart")]
    LogsStart {
        #[serde(rename = "buildId")]
        build_id: u64,
        #[serde(rename = "stepId")]
        step_id: Option<u64>,
        success: bool,
        details: String,
    },

    #[serde(rename = "logsEnd")]
    LogsEnd {
        #[serde(rename = "buildId")]
        build_id: u64,
        #[serde(rename = "stepId")]
        step_id: Option<u64>,
        success: bool,
        details: String,
    },

    #[serde(rename = "stepFinished")]
    StepFinished {
        #[serde(rename = "buildId")]
        build_id: u64,
        #[serde(rename = "stepId")]
        step_id: u64,
    },

    #[serde(rename = "buildFinished")]
    BuildFinished {
        #[serde(rename = "buildId")]
        build_id: u64,
    },

    #[serde(rename = "logLine")]
    LogLine {
        #[serde(rename = "buildId")]
        build_id: u64,
        #[serde(rename = "stepId")]
        step_id: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        timestamp: Option<jiff::Timestamp>,
        line: String,
    },
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(tag = "type")]
pub enum HydraWsRequest {
    #[serde(rename = "ping")]
    Ping {},

    #[serde(rename = "logsStart")]
    LogsStart {
        #[serde(rename = "buildId")]
        build_id: u64,
        #[serde(rename = "stepId")]
        step_id: Option<u64>,
    },

    #[serde(rename = "logsEnd")]
    LogsEnd {
        #[serde(rename = "buildId")]
        build_id: u64,
        #[serde(rename = "stepId")]
        step_id: Option<u64>,
    },
}

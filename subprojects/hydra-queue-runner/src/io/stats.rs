#[derive(Debug, thiserror::Error)]
pub enum CgroupError {
    #[error("reading cgroup file")]
    Io(#[from] std::io::Error),

    #[error("reading process info")]
    Proc(#[from] procfs::ProcError),

    #[error("failed to parse cgroup value `{field}`")]
    Parse {
        field: &'static str,
        #[source]
        source: std::num::ParseIntError,
    },

    #[error("cgroup information is missing in process")]
    NoCgroup,

    #[error("cgroups directory does not exist")]
    NoCgroupDir,
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildQueueStats {
    active_runnable: u64,
    total_runnable: u64,
    nr_runnable_waiting: u64,
    nr_runnable_disabled: u64,
    avg_runnable_time: u64,
    wait_time_ms: u64,
}

impl From<crate::state::BuildQueueStats> for BuildQueueStats {
    fn from(v: crate::state::BuildQueueStats) -> Self {
        Self {
            active_runnable: v.active_runnable,
            total_runnable: v.total_runnable,
            nr_runnable_waiting: v.nr_runnable_waiting,
            nr_runnable_disabled: v.nr_runnable_disabled,
            avg_runnable_time: v.avg_runnable_time,
            wait_time_ms: v.wait_time,
        }
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_field_names)]
pub struct MemoryStats {
    current_bytes: u64,
    peak_bytes: u64,
    swap_current_bytes: u64,
    zswap_current_bytes: u64,
}

impl MemoryStats {
    #[tracing::instrument(err)]
    fn new(cgroups_path: &std::path::Path) -> Result<Self, CgroupError> {
        Ok(Self {
            current_bytes: fs_err::read_to_string(cgroups_path.join("memory.current"))?
                .trim()
                .parse()
                .map_err(|source| CgroupError::Parse {
                    field: "memory.current",
                    source,
                })?,
            peak_bytes: fs_err::read_to_string(cgroups_path.join("memory.peak"))?
                .trim()
                .parse()
                .map_err(|source| CgroupError::Parse {
                    field: "memory.peak",
                    source,
                })?,
            swap_current_bytes: fs_err::read_to_string(cgroups_path.join("memory.swap.current"))?
                .trim()
                .parse()
                .map_err(|source| CgroupError::Parse {
                    field: "memory.swap.current",
                    source,
                })?,
            zswap_current_bytes: fs_err::read_to_string(cgroups_path.join("memory.zswap.current"))?
                .trim()
                .parse()
                .map_err(|source| CgroupError::Parse {
                    field: "memory.zswap.current",
                    source,
                })?,
        })
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IoStats {
    total_read_bytes: u64,
    total_write_bytes: u64,
}

impl IoStats {
    #[tracing::instrument(err)]
    fn new(cgroups_path: &std::path::Path) -> Result<Self, CgroupError> {
        let mut total_read_bytes: u64 = 0;
        let mut total_write_bytes: u64 = 0;

        let contents = fs_err::read_to_string(cgroups_path.join("io.stat"))?;
        for line in contents.lines() {
            for part in line.split_whitespace() {
                if part.starts_with("rbytes=") {
                    total_read_bytes += part
                        .split('=')
                        .nth(1)
                        .and_then(|v| v.trim().parse().ok())
                        .unwrap_or(0);
                } else if part.starts_with("wbytes=") {
                    total_write_bytes += part
                        .split('=')
                        .nth(1)
                        .and_then(|v| v.trim().parse().ok())
                        .unwrap_or(0);
                }
            }
        }

        Ok(Self {
            total_read_bytes,
            total_write_bytes,
        })
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
#[allow(clippy::struct_field_names)]
pub struct CpuStats {
    usage_usec: u128,
    user_usec: u128,
    system_usec: u128,
}

impl CpuStats {
    #[tracing::instrument(err)]
    fn new(cgroups_path: &std::path::Path) -> Result<Self, CgroupError> {
        let contents = fs_err::read_to_string(cgroups_path.join("cpu.stat"))?;

        let mut usage_usec: u128 = 0;
        let mut user_usec: u128 = 0;
        let mut system_usec: u128 = 0;

        for line in contents.lines() {
            if line.starts_with("usage_usec") {
                usage_usec = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0);
            } else if line.starts_with("user_usec") {
                user_usec = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0);
            } else if line.starts_with("system_usec") {
                system_usec = line
                    .split_whitespace()
                    .nth(1)
                    .and_then(|v| v.trim().parse().ok())
                    .unwrap_or(0);
            }
        }
        Ok(Self {
            usage_usec,
            user_usec,
            system_usec,
        })
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CgroupStats {
    memory: MemoryStats,
    io: IoStats,
    cpu: CpuStats,
}

impl CgroupStats {
    #[tracing::instrument(err)]
    fn new(me: &procfs::process::Process) -> Result<Self, CgroupError> {
        let cgroups_pathname = format!(
            "/sys/fs/cgroup/{}",
            me.cgroups()?
                .0
                .first()
                .ok_or(CgroupError::NoCgroup)?
                .pathname
        );
        let cgroups_path = std::path::Path::new(&cgroups_pathname);
        if !cgroups_path.exists() {
            return Err(CgroupError::NoCgroupDir);
        }

        Ok(Self {
            memory: MemoryStats::new(cgroups_path)?,
            io: IoStats::new(cgroups_path)?,
            cpu: CpuStats::new(cgroups_path)?,
        })
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Process {
    pid: i32,
    vsize_bytes: u64,
    rss_bytes: u64,
    shared_bytes: u64,
    cgroup: Option<CgroupStats>,
}

impl Process {
    pub fn new() -> Option<Self> {
        let me = procfs::process::Process::myself().ok()?;
        let page_size = procfs::page_size();
        let statm = me.statm().ok()?;
        let vsize = statm.size * page_size;
        let rss = statm.resident * page_size;
        let shared = statm.shared * page_size;
        Some(Self {
            pid: me.pid,
            vsize_bytes: vsize,
            rss_bytes: rss,
            shared_bytes: shared,
            cgroup: match CgroupStats::new(&me) {
                Ok(v) => Some(v),
                Err(e) => {
                    tracing::error!("failed to cgroups stats: {e}");
                    None
                }
            },
        })
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StoreStats {
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
    nar_compression_savings: f64,
    nar_compression_speed: f64,
}

impl StoreStats {
    #[must_use]
    pub fn new(v: &StoreStats) -> Self {
        Self {
            nar_info_read: v.nar_info_read,
            nar_info_read_averted: v.nar_info_read_averted,
            nar_info_missing: v.nar_info_missing,
            nar_info_write: v.nar_info_write,
            path_info_cache_size: v.path_info_cache_size,
            nar_read: v.nar_read,
            nar_read_bytes: v.nar_read_bytes,
            nar_read_compressed_bytes: v.nar_read_compressed_bytes,
            nar_write: v.nar_write,
            nar_write_averted: v.nar_write_averted,
            nar_write_bytes: v.nar_write_bytes,
            nar_write_compressed_bytes: v.nar_write_compressed_bytes,
            nar_write_compression_time_ms: v.nar_write_compression_time_ms,
            nar_compression_savings: 0.0, // not available via daemon protocol
            nar_compression_speed: 0.0,   // not available via daemon protocol
        }
    }
}

#[derive(Debug, Clone, Copy, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct S3Stats {
    put: u64,
    put_bytes: u64,
    put_time_ms: u64,
    put_speed: f64,
    get: u64,
    get_bytes: u64,
    get_time_ms: u64,
    get_speed: f64,
    head: u64,
    cost_dollar_approx: f64,
}

impl S3Stats {
    #[must_use]
    pub fn new(v: &binary_cache::S3Stats) -> Self {
        Self {
            put: v.put,
            put_bytes: v.put_bytes,
            put_time_ms: v.put_time_ms,
            put_speed: v.put_speed(),
            get: v.get,
            get_bytes: v.get_bytes,
            get_time_ms: v.get_time_ms,
            get_speed: v.get_speed(),
            head: v.head,
            cost_dollar_approx: v.cost_dollar_approx(),
        }
    }
}

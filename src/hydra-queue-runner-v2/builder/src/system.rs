use procfs_core::FromRead as _;

pub struct BaseSystemInfo {
    pub cpu_count: usize,
    pub bogomips: f32,
    pub total_memory: u64,
}

impl BaseSystemInfo {
    #[cfg(target_os = "linux")]
    pub fn new() -> anyhow::Result<Self> {
        let cpuinfo = procfs_core::CpuInfo::from_file("/proc/cpuinfo")?;
        let meminfo = procfs_core::Meminfo::from_file("/proc/meminfo")?;
        let bogomips = cpuinfo
            .fields
            .get("bogomips")
            .and_then(|v| v.parse::<f32>().ok())
            .unwrap_or(0.0);

        Ok(Self {
            cpu_count: cpuinfo.num_cores(),
            bogomips,
            total_memory: meminfo.mem_total,
        })
    }

    #[cfg(target_os = "macos")]
    pub fn new() -> anyhow::Result<Self> {
        let mut sys = sysinfo::System::new_all();
        sys.refresh_memory();
        sys.refresh_cpu_all();

        Ok(Self {
            cpu_count: sys.cpus().len(),
            bogomips: 0.0,
            total_memory: sys.total_memory(),
        })
    }
}

pub struct Pressure {
    pub avg10: f32,
    pub avg60: f32,
    pub avg300: f32,
    pub total: u64,
}

#[cfg(target_os = "linux")]
impl Pressure {
    fn new(record: &procfs_core::PressureRecord) -> Self {
        Self {
            avg10: record.avg10,
            avg60: record.avg60,
            avg300: record.avg300,
            total: record.total,
        }
    }
}

impl From<Pressure> for crate::runner_v1::Pressure {
    fn from(val: Pressure) -> Self {
        Self {
            avg10: val.avg10,
            avg60: val.avg60,
            avg300: val.avg300,
            total: val.total,
        }
    }
}

pub struct PressureState {
    pub cpu_some: Option<Pressure>,
    pub mem_some: Option<Pressure>,
    pub mem_full: Option<Pressure>,
    pub io_some: Option<Pressure>,
    pub io_full: Option<Pressure>,
    pub irq_full: Option<Pressure>,
}

// TODO: remove once https://github.com/eminence/procfs/issues/351 is resolved
// Next 3 Functions are copied from https://github.com/eminence/procfs/blob/v0.17.0/procfs-core/src/pressure.rs#L93
// LICENSE is Apache2.0/MIT
#[cfg(target_os = "linux")]
fn get_f32(
    map: &std::collections::HashMap<&str, &str>,
    value: &str,
) -> procfs_core::ProcResult<f32> {
    map.get(value).map_or_else(
        || Err(procfs_core::ProcError::Incomplete(None)),
        |v| {
            v.parse::<f32>()
                .map_err(|_| procfs_core::ProcError::Incomplete(None))
        },
    )
}

#[cfg(target_os = "linux")]
fn get_total(map: &std::collections::HashMap<&str, &str>) -> procfs_core::ProcResult<u64> {
    map.get("total").map_or_else(
        || Err(procfs_core::ProcError::Incomplete(None)),
        |v| {
            v.parse::<u64>()
                .map_err(|_| procfs_core::ProcError::Incomplete(None))
        },
    )
}

#[cfg(target_os = "linux")]
fn parse_pressure_record(line: &str) -> procfs_core::ProcResult<procfs_core::PressureRecord> {
    let mut parsed = std::collections::HashMap::new();

    if !line.starts_with("some") && !line.starts_with("full") {
        return Err(procfs_core::ProcError::Incomplete(None));
    }

    let values = &line[5..];

    for kv_str in values.split_whitespace() {
        let kv_split = kv_str.split('=');
        let vec: Vec<&str> = kv_split.collect();
        if vec.len() == 2 {
            parsed.insert(vec[0], vec[1]);
        }
    }

    Ok(procfs_core::PressureRecord {
        avg10: get_f32(&parsed, "avg10")?,
        avg60: get_f32(&parsed, "avg60")?,
        avg300: get_f32(&parsed, "avg300")?,
        total: get_total(&parsed)?,
    })
}

#[cfg(target_os = "linux")]
impl PressureState {
    pub fn new() -> Option<Self> {
        if !std::fs::exists("/proc/pressure").unwrap_or_default() {
            return None;
        }

        let cpu_psi = procfs_core::CpuPressure::from_file("proc/pressure/cpu").ok();
        let mem_psi = procfs_core::MemoryPressure::from_file("/proc/pressure/memory").ok();
        let io_psi = procfs_core::IoPressure::from_file("/proc/pressure/io").ok();
        let irq_psi_full = std::fs::read_to_string("/proc/pressure/irq")
            .ok()
            .and_then(|v| parse_pressure_record(&v).ok());

        Some(Self {
            cpu_some: cpu_psi.map(|v| Pressure::new(&v.some)),
            mem_some: mem_psi.as_ref().map(|v| Pressure::new(&v.some)),
            mem_full: mem_psi.map(|v| Pressure::new(&v.full)),
            io_some: io_psi.as_ref().map(|v| Pressure::new(&v.some)),
            io_full: io_psi.map(|v| Pressure::new(&v.full)),
            irq_full: irq_psi_full.map(|v| Pressure::new(&v)),
        })
    }
}

pub struct SystemLoad {
    pub load_avg_1: f32,
    pub load_avg_5: f32,
    pub load_avg_15: f32,

    pub mem_usage: u64,
    pub pressure: Option<PressureState>,

    pub tmp_free_percent: f64,
    pub store_free_percent: f64,
}

pub fn get_mount_free_percent(dest: &str) -> anyhow::Result<f64> {
    let stat = nix::sys::statvfs::statvfs(dest)?;

    let total_bytes = (stat.blocks() as u64) * stat.block_size();
    let free_bytes = (stat.blocks_available() as u64) * stat.block_size();
    #[allow(clippy::cast_precision_loss)]
    Ok(free_bytes as f64 / total_bytes as f64 * 100.0)
}

impl SystemLoad {
    #[cfg(target_os = "linux")]
    pub fn new() -> anyhow::Result<Self> {
        let meminfo = procfs_core::Meminfo::from_file("/proc/meminfo")?;
        let load = procfs_core::LoadAverage::from_file("/proc/loadavg")?;

        // TODO: prefix
        let nix_store_dir = std::env::var("NIX_STORE_DIR").unwrap_or("/nix/store".to_owned());

        Ok(Self {
            load_avg_1: load.one,
            load_avg_5: load.five,
            load_avg_15: load.fifteen,
            mem_usage: meminfo.mem_total - meminfo.mem_available.unwrap_or(0),
            pressure: PressureState::new(),
            tmp_free_percent: get_mount_free_percent("/tmp").unwrap_or(0.),
            store_free_percent: get_mount_free_percent(&nix_store_dir).unwrap_or(0.),
        })
    }

    #[cfg(target_os = "macos")]
    pub fn new() -> anyhow::Result<Self> {
        let mut sys = sysinfo::System::new_all();
        sys.refresh_memory();
        let load = sysinfo::System::load_average();

        // TODO: prefix
        let nix_store_dir = std::env::var("NIX_STORE_DIR").unwrap_or("/nix/store".to_owned());

        Ok(Self {
            load_avg_1: load.one as f32,
            load_avg_5: load.five as f32,
            load_avg_15: load.fifteen as f32,
            mem_usage: sys.used_memory(),
            pressure: None,
            tmp_free_percent: get_mount_free_percent("/tmp").unwrap_or(0.),
            store_free_percent: get_mount_free_percent(&nix_store_dir).unwrap_or(0.),
        })
    }
}

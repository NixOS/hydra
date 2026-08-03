use color_eyre::eyre;
use hashbrown::HashMap;
use procfs_core::FromRead as _;

#[derive(Debug, Clone, Copy)]
pub struct BaseSystemInfo {
    pub cpu_count: usize,
    pub bogomips: f32,
    pub total_memory: u64,
}

impl BaseSystemInfo {
    #[cfg(target_os = "linux")]
    #[tracing::instrument(err)]
    pub fn new() -> eyre::Result<Self> {
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
    #[tracing::instrument(err)]
    pub fn new() -> eyre::Result<Self> {
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

pub use hydra_proto::{Pressure, PressureState};

#[cfg(target_os = "linux")]
fn pressure_from_record(record: &procfs_core::PressureRecord) -> Pressure {
    Pressure {
        avg10: record.avg10,
        avg60: record.avg60,
        avg300: record.avg300,
        total: record.total,
    }
}

// TODO: remove once https://github.com/eminence/procfs/issues/351 is resolved
// Next 3 Functions are copied from https://github.com/eminence/procfs/blob/v0.17.0/procfs-core/src/pressure.rs#L93
// LICENSE is Apache2.0/MIT
#[cfg(target_os = "linux")]
fn get_f32(map: &HashMap<&str, &str>, value: &str) -> procfs_core::ProcResult<f32> {
    map.get(value).map_or_else(
        || Err(procfs_core::ProcError::Incomplete(None)),
        |v| {
            v.parse::<f32>()
                .map_err(|_| procfs_core::ProcError::Incomplete(None))
        },
    )
}

#[cfg(target_os = "linux")]
fn get_total(map: &HashMap<&str, &str>) -> procfs_core::ProcResult<u64> {
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
    let mut parsed = HashMap::with_capacity(4);

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
#[must_use]
pub fn read_pressure_state() -> Option<PressureState> {
    if !fs_err::exists("/proc/pressure").unwrap_or_default() {
        return None;
    }

    let cpu_psi = procfs_core::CpuPressure::from_file("/proc/pressure/cpu").ok();
    let mem_psi = procfs_core::MemoryPressure::from_file("/proc/pressure/memory").ok();
    let io_psi = procfs_core::IoPressure::from_file("/proc/pressure/io").ok();
    let irq_psi_full = fs_err::read_to_string("/proc/pressure/irq")
        .ok()
        .and_then(|v| parse_pressure_record(&v).ok());

    Some(PressureState {
        cpu_some: cpu_psi.map(|v| pressure_from_record(&v.some)),
        mem_some: mem_psi.as_ref().map(|v| pressure_from_record(&v.some)),
        mem_full: mem_psi.map(|v| pressure_from_record(&v.full)),
        io_some: io_psi.as_ref().map(|v| pressure_from_record(&v.some)),
        io_full: io_psi.map(|v| pressure_from_record(&v.full)),
        irq_full: irq_psi_full.as_ref().map(pressure_from_record),
    })
}

#[derive(Debug, Clone, Copy)]
pub struct SystemLoad {
    pub load_avg_1: f32,
    pub load_avg_5: f32,
    pub load_avg_15: f32,

    pub mem_usage: u64,
    pub pressure: Option<PressureState>,

    pub build_dir_free_percent: f64,
    pub store_free_percent: f64,
}

#[tracing::instrument(err)]
pub fn get_mount_free_percent(dest: &str) -> eyre::Result<f64> {
    let stat = nix::sys::statvfs::statvfs(dest)?;

    let total_bytes = (stat.blocks() as u64) * stat.block_size();
    let free_bytes = (stat.blocks_available() as u64) * stat.block_size();
    #[allow(clippy::cast_precision_loss)]
    Ok(free_bytes as f64 / total_bytes as f64 * 100.0)
}

impl SystemLoad {
    #[cfg(target_os = "linux")]
    #[tracing::instrument(err)]
    pub fn new(build_dir: &str, store_dir: &str) -> eyre::Result<Self> {
        let meminfo = procfs_core::Meminfo::from_file("/proc/meminfo")?;
        let load = procfs_core::LoadAverage::from_file("/proc/loadavg")?;

        Ok(Self {
            load_avg_1: load.one,
            load_avg_5: load.five,
            load_avg_15: load.fifteen,
            mem_usage: meminfo.mem_total - meminfo.mem_available.unwrap_or(0),
            pressure: read_pressure_state(),
            build_dir_free_percent: get_mount_free_percent(build_dir).unwrap_or(100.),
            store_free_percent: get_mount_free_percent(store_dir).unwrap_or(100.),
        })
    }

    #[cfg(target_os = "macos")]
    #[tracing::instrument(err)]
    pub fn new(build_dir: &str, store_dir: &str) -> eyre::Result<Self> {
        let mut sys = sysinfo::System::new_all();
        sys.refresh_memory();
        let load = sysinfo::System::load_average();

        Ok(Self {
            load_avg_1: load.one as f32,
            load_avg_5: load.five as f32,
            load_avg_15: load.fifteen as f32,
            mem_usage: sys.used_memory(),
            pressure: None,
            build_dir_free_percent: get_mount_free_percent(build_dir).unwrap_or(0.),
            store_free_percent: get_mount_free_percent(store_dir).unwrap_or(0.),
        })
    }
}

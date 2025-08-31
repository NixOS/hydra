use std::{
    collections::BTreeMap,
    sync::atomic::{AtomicI64, AtomicU32, Ordering},
};

pub type JobsetID = i32;
pub const SCHEDULING_WINDOW: i64 = 24 * 60 * 60;

#[derive(Debug)]
pub struct Jobset {
    pub id: JobsetID,
    pub project_name: String,
    pub name: String,

    seconds: AtomicI64,
    shares: AtomicU32,
    // The start time and duration of the most recent build steps.
    steps: parking_lot::RwLock<BTreeMap<i64, i64>>,
}

impl PartialEq for Jobset {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id && self.project_name == other.project_name && self.name == other.name
    }
}

impl Eq for Jobset {}

impl std::hash::Hash for Jobset {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.id.hash(state);
        self.project_name.hash(state);
        self.name.hash(state);
    }
}

impl Jobset {
    pub fn new<S: Into<String>>(id: JobsetID, project_name: S, name: S) -> Self {
        Self {
            id,
            project_name: project_name.into(),
            name: name.into(),
            seconds: 0.into(),
            shares: 0.into(),
            steps: parking_lot::RwLock::new(BTreeMap::new()),
        }
    }

    pub fn full_name(&self) -> String {
        format!("{}:{}", self.project_name, self.name)
    }

    pub fn share_used(&self) -> f64 {
        let seconds = self.seconds.load(Ordering::Relaxed);
        let shares = self.shares.load(Ordering::Relaxed);

        // we dont care about the precision here
        #[allow(clippy::cast_precision_loss)]
        ((seconds as f64) / f64::from(shares))
    }

    pub fn set_shares(&self, shares: i32) -> anyhow::Result<()> {
        debug_assert!(shares > 0);
        self.shares.store(shares.try_into()?, Ordering::Relaxed);
        Ok(())
    }

    pub fn get_shares(&self) -> u32 {
        self.shares.load(Ordering::Relaxed)
    }

    pub fn get_seconds(&self) -> i64 {
        self.seconds.load(Ordering::Relaxed)
    }

    pub fn add_step(&self, start_time: i64, duration: i64) {
        let mut steps = self.steps.write();
        steps.insert(start_time, duration);
        self.seconds.fetch_add(duration, Ordering::Relaxed);
    }

    pub fn prune_steps(&self) {
        let now = chrono::Utc::now().timestamp();
        let mut steps = self.steps.write();

        loop {
            let Some(first) = steps.first_entry() else {
                break;
            };
            let start_time = *first.key();

            if start_time > now - SCHEDULING_WINDOW {
                break;
            }
            self.seconds.fetch_sub(*first.get(), Ordering::Relaxed);
            steps.remove(&start_time);
        }
    }
}

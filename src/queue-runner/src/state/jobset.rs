use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};

use hashbrown::HashMap;

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
        self.steps.write().insert(start_time, duration);
        self.seconds.fetch_add(duration, Ordering::Relaxed);
    }

    pub fn prune_steps(&self) {
        let now = jiff::Timestamp::now().as_second();
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

// Projectname, Jobsetname
type JobsetName = (String, String);

#[derive(Clone)]
pub struct Jobsets {
    inner: Arc<parking_lot::RwLock<HashMap<JobsetName, Arc<Jobset>>>>,
}

impl Default for Jobsets {
    fn default() -> Self {
        Self::new()
    }
}

impl Jobsets {
    #[must_use]
    pub fn new() -> Self {
        Self {
            inner: Arc::new(parking_lot::RwLock::new(HashMap::with_capacity(100))),
        }
    }

    #[must_use]
    pub fn len(&self) -> usize {
        self.inner.read().len()
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.inner.read().is_empty()
    }

    #[must_use]
    pub fn clone_as_io(&self) -> HashMap<String, crate::io::Jobset> {
        let jobsets = self.inner.read();
        jobsets
            .values()
            .map(|v| (v.full_name(), v.clone().into()))
            .collect()
    }

    #[tracing::instrument(skip(self))]
    pub fn prune(&self) {
        let jobsets = self.inner.read();
        for ((project_name, jobset_name), jobset) in jobsets.iter() {
            let s1 = jobset.share_used();
            jobset.prune_steps();
            let s2 = jobset.share_used();
            if (s1 - s2).abs() > f64::EPSILON {
                tracing::debug!(
                    "pruned scheduling window of '{project_name}:{jobset_name}' from {s1} to {s2}"
                );
            }
        }
    }

    #[tracing::instrument(skip(self, conn), err)]
    pub async fn create(
        &self,
        conn: &mut db::Connection,
        jobset_id: i32,
        project_name: &str,
        jobset_name: &str,
    ) -> anyhow::Result<Arc<Jobset>> {
        let key = (project_name.to_owned(), jobset_name.to_owned());
        {
            let jobsets = self.inner.read();
            if let Some(jobset) = jobsets.get(&key) {
                return Ok(jobset.clone());
            }
        }

        let shares = conn
            .get_jobset_scheduling_shares(jobset_id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("Scheduling Shares not found for jobset not found."))?;
        let jobset = Jobset::new(jobset_id, project_name, jobset_name);
        jobset.set_shares(shares)?;

        for step in conn
            .get_jobset_build_steps(jobset_id, SCHEDULING_WINDOW)
            .await?
        {
            let Some(starttime) = step.starttime else {
                continue;
            };
            let Some(stoptime) = step.stoptime else {
                continue;
            };
            jobset.add_step(i64::from(starttime), i64::from(stoptime - starttime));
        }

        let jobset = Arc::new(jobset);
        {
            let mut jobsets = self.inner.write();
            jobsets.insert(key, jobset.clone());
        }

        Ok(jobset)
    }

    #[tracing::instrument(skip(self, conn), err)]
    pub async fn handle_change(&self, conn: &mut db::Connection) -> anyhow::Result<()> {
        let curr_jobsets_in_db = conn.get_jobsets().await?;

        let jobsets = self.inner.read();
        for row in curr_jobsets_in_db {
            if let Some(i) = jobsets.get(&(row.project.clone(), row.name.clone()))
                && let Err(e) = i.set_shares(row.schedulingshares)
            {
                tracing::error!(
                    "Failed to update jobset scheduling shares. project_name={} jobset_name={} e={}",
                    row.project,
                    row.name,
                    e,
                );
            }
        }
        Ok(())
    }
}

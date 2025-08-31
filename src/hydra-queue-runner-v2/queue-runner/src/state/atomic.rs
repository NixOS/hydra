use chrono::{DateTime, Utc};
use std::sync::atomic::{AtomicI64, Ordering};

#[derive(Debug)]
pub struct AtomicDateTime {
    inner: AtomicI64,
}

impl Default for AtomicDateTime {
    fn default() -> Self {
        AtomicDateTime::new(Utc::now())
    }
}

impl AtomicDateTime {
    pub fn new(dt: DateTime<Utc>) -> Self {
        Self {
            inner: AtomicI64::new(
                dt
                    .timestamp_nanos_opt()
                    .expect("datetime not in range: 1677-09-21T00:12:43.145224192 and 2262-04-11T23:47:16.854775807."),
            ),
        }
    }

    pub fn load(&self) -> DateTime<Utc> {
        let nanos = self.inner.load(Ordering::Relaxed);
        DateTime::<Utc>::from_timestamp_nanos(nanos)
    }

    pub fn store(&self, dt: DateTime<Utc>) {
        if let Some(v) = dt.timestamp_nanos_opt() {
            self.inner.store(v, Ordering::Relaxed);
        }
    }
}

use jiff::Timestamp;
use std::sync::atomic::{AtomicI32, AtomicI64, Ordering};

#[derive(Debug)]
pub struct AtomicDateTime {
    seconds: AtomicI64,
    nanoseconds: AtomicI32,
}

impl Default for AtomicDateTime {
    fn default() -> Self {
        Self::new(Timestamp::now())
    }
}

impl AtomicDateTime {
    #[must_use]
    pub fn new(dt: Timestamp) -> Self {
        Self {
            seconds: AtomicI64::new(dt.as_second()),
            nanoseconds: AtomicI32::new(dt.subsec_nanosecond()),
        }
    }

    pub fn load(&self) -> Timestamp {
        let seconds = self.seconds.load(Ordering::Relaxed);
        let nanoseconds = self.nanoseconds.load(Ordering::Relaxed);
        Timestamp::new(seconds, nanoseconds).unwrap_or_default()
    }

    pub fn store(&self, dt: Timestamp) {
        self.seconds.store(dt.as_second(), Ordering::Relaxed);
        self.nanoseconds
            .store(dt.subsec_nanosecond(), Ordering::Relaxed);
    }
}

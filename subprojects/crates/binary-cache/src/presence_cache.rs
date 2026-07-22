//! Persistent positive cache for narinfo presence.
//!
//! A narinfo HEAD costs ~165ms and the same heavily-shared inputs (stdenv,
//! bash, ...) are checked over and over; the in-memory cache also starts cold
//! after a restart. Persisting recent present paths in `SQLite` avoids both.
//!
//! Only positive results are cached, with a TTL: the cache can garbage-collect
//! a path, so a stale "present" must expire and fall back to a real HEAD.

use std::time::Duration;

use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteSynchronous};

#[derive(Debug, Clone)]
pub(crate) struct PresenceCache {
    pool: sqlx::SqlitePool,
    ttl: Duration,
}

fn now_epoch() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .try_into()
        .unwrap_or(i64::MAX)
}

impl PresenceCache {
    pub(crate) async fn open(path: &std::path::Path, ttl: Duration) -> Result<Self, sqlx::Error> {
        if let Some(parent) = path.parent() {
            fs_err::tokio::create_dir_all(parent)
                .await
                .map_err(sqlx::Error::Io)?;
        }
        // It is only a cache, so trade durability for far fewer fsyncs: WAL
        // plus synchronous=NORMAL avoids a sync per write, which on ZFS is a
        // ZIL commit and dominated ingestion time.
        let opts = SqliteConnectOptions::new()
            .filename(path)
            .create_if_missing(true)
            .journal_mode(SqliteJournalMode::Wal)
            .synchronous(SqliteSynchronous::Normal)
            .busy_timeout(Duration::from_secs(30));
        let pool = SqlitePoolOptions::new()
            .max_connections(4)
            .connect_with(opts)
            .await?;
        sqlx::query(
            "CREATE TABLE IF NOT EXISTS narinfo_presence (
                 hash   TEXT PRIMARY KEY,
                 expiry INTEGER NOT NULL
             )",
        )
        .execute(&pool)
        .await?;
        Ok(Self { pool, ttl })
    }

    pub(crate) async fn is_present(&self, hash: &str) -> bool {
        let row: Result<Option<(i64,)>, _> =
            sqlx::query_as("SELECT expiry FROM narinfo_presence WHERE hash = ?")
                .bind(hash)
                .fetch_optional(&self.pool)
                .await;
        match row {
            Ok(Some((expiry,))) => expiry > now_epoch(),
            Ok(None) => false,
            Err(e) => {
                tracing::warn!("presence cache read for {hash} failed: {e}");
                false
            }
        }
    }

    pub(crate) async fn record_present(&self, hash: &str) {
        let expiry =
            now_epoch().saturating_add(i64::try_from(self.ttl.as_secs()).unwrap_or(i64::MAX));
        if let Err(e) =
            sqlx::query("INSERT OR REPLACE INTO narinfo_presence (hash, expiry) VALUES (?, ?)")
                .bind(hash)
                .bind(expiry)
                .execute(&self.pool)
                .await
        {
            tracing::warn!("presence cache write for {hash} failed: {e}");
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[tokio::test]
    async fn records_and_expires() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("presence.db");

        let cache = PresenceCache::open(&path, Duration::from_mins(1))
            .await
            .unwrap();
        assert!(!cache.is_present("abc").await);
        cache.record_present("abc").await;
        assert!(cache.is_present("abc").await);

        // A zero TTL entry is immediately stale.
        let expiring = PresenceCache::open(&path, Duration::ZERO).await.unwrap();
        expiring.record_present("def").await;
        assert!(!expiring.is_present("def").await);
    }

    #[tokio::test]
    async fn survives_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("presence.db");
        {
            let cache = PresenceCache::open(&path, Duration::from_mins(1))
                .await
                .unwrap();
            cache.record_present("persisted").await;
        }
        let reopened = PresenceCache::open(&path, Duration::from_mins(1))
            .await
            .unwrap();
        assert!(reopened.is_present("persisted").await);
    }
}

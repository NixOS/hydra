#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    clippy::pedantic,
    clippy::expect_used,
    clippy::unwrap_used,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    missing_copy_implementations,
    unused_qualifications
)]
#![allow(clippy::missing_errors_doc)]

mod connection;
mod error;
pub mod models;

use std::str::FromStr as _;

pub use connection::{Connection, Transaction};
pub use error::{DataError, Error, Result};
pub use harmonia_store_path::StoreDir;
pub use sqlx::postgres::PgNotification as Notification;

/// Error that a serialization-failure retry can recognise.
pub trait RetryableError {
    /// True if this error was a rolled-back Postgres serialization failure or
    /// deadlock that is safe to retry from the top.
    fn is_retryable_serialization_failure(&self) -> bool;
}

impl RetryableError for Error {
    fn is_retryable_serialization_failure(&self) -> bool {
        // 40001 = serialization_failure, 40P01 = deadlock_detected. The server
        // rolled the transaction back, so retrying from the top is safe.
        matches!(self, Self::Sql(sqlx::Error::Database(db))
            if matches!(db.code().as_deref(), Some("40001" | "40P01")))
    }
}

const SERIALIZATION_RETRY_ATTEMPTS: u32 = 10;

/// Retry `f` when it fails with a Postgres serialization failure or deadlock.
///
/// `f` must acquire its own connection and open its own transaction so that a
/// retry starts from a clean state.
pub async fn retry_serialization_failures<F, Fut, T, E>(
    what: &str,
    mut f: F,
) -> std::result::Result<T, E>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = std::result::Result<T, E>>,
    E: RetryableError + std::fmt::Display,
{
    let mut attempt = 1;
    loop {
        match f().await {
            Err(e)
                if e.is_retryable_serialization_failure()
                    && attempt < SERIALIZATION_RETRY_ATTEMPTS =>
            {
                tracing::warn!(
                    "{what}: serialization failure, retrying ({attempt}/{SERIALIZATION_RETRY_ATTEMPTS}): {e}"
                );
                tokio::time::sleep(std::time::Duration::from_millis(u64::from(attempt) * 50)).await;
                attempt += 1;
            }
            other => return other,
        }
    }
}

#[derive(Debug, Clone)]
pub struct Database {
    pool: sqlx::PgPool,
}

// Retry a briefly-exhausted pool instead of blocking one acquire for sqlx's
// 30s default, so a spike does not fail a critical-path caller (e.g. build
// finalization). Total wait is ACQUIRE_TIMEOUT * ACQUIRE_ATTEMPTS.
const ACQUIRE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
const ACQUIRE_ATTEMPTS: u32 = 6;

impl Database {
    pub async fn new(url: &str, max_connections: u32) -> Result<Self> {
        Ok(Self {
            pool: sqlx::postgres::PgPoolOptions::new()
                .max_connections(max_connections)
                .acquire_timeout(ACQUIRE_TIMEOUT)
                .connect(url)
                .await?,
        })
    }

    pub async fn get(&self) -> Result<Connection> {
        for attempt in 1..=ACQUIRE_ATTEMPTS {
            match self.pool.acquire().await {
                Ok(conn) => return Ok(Connection::new(conn)),
                Err(sqlx::Error::PoolTimedOut) if attempt < ACQUIRE_ATTEMPTS => {
                    tracing::warn!(
                        "db pool exhausted, retrying acquire ({attempt}/{ACQUIRE_ATTEMPTS})"
                    );
                }
                Err(e) => return Err(e.into()),
            }
        }
        Err(sqlx::Error::PoolTimedOut.into())
    }

    #[tracing::instrument(skip(self, url), err)]
    pub fn reconfigure_pool(&self, url: &str) -> Result<()> {
        // TODO: ability to change max_connections by dropping the pool and recreating it
        self.pool
            .set_connect_options(sqlx::postgres::PgConnectOptions::from_str(url)?);
        Ok(())
    }

    pub async fn listener(
        &self,
        channels: Vec<&str>,
    ) -> Result<
        impl futures::Stream<Item = std::result::Result<sqlx::postgres::PgNotification, sqlx::Error>>
        + Unpin,
    > {
        let mut listener = sqlx::postgres::PgListener::connect_with(&self.pool).await?;
        listener.listen_all(channels).await?;
        Ok(listener.into_stream())
    }
}

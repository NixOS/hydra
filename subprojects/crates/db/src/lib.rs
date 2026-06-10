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
pub use error::{DataError, DbConfigurationError, Error, Result};
pub use harmonia_store_path::StoreDir;

#[derive(Debug, Clone)]
pub struct Database {
    pool: sqlx::PgPool,
}

impl Database {
    pub async fn new(url: &str, max_connections: u32) -> Result<Self> {
        Ok(Self {
            pool: sqlx::postgres::PgPoolOptions::new()
                .max_connections(max_connections)
                .connect(url)
                .await?,
        })
    }

    pub async fn get(&self) -> Result<Connection> {
        let conn = self.pool.acquire().await?;
        Ok(Connection::new(conn))
    }

    /// Re-configure the connection pool with a new URL.
    ///
    /// This only parses and stores the new options — it does **not**
    /// contact the database.
    // TODO: ability to change max_connections by dropping the pool and recreating it
    #[tracing::instrument(skip(self, url), err)]
    pub fn reconfigure_pool(&self, url: &str) -> std::result::Result<(), DbConfigurationError> {
        match sqlx::postgres::PgConnectOptions::from_str(url) {
            Ok(options) => {
                self.pool.set_connect_options(options);
                Ok(())
            }
            Err(sqlx::Error::Configuration(e)) => Err(DbConfigurationError(e)),
            Err(e) => {
                // PgConnectOptions::from_str only produces Configuration
                // errors. If this changes in a future sqlx version, fail
                // loudly rather than silently swallowing it.
                panic!("unexpected error from PgConnectOptions::from_str: {e}")
            }
        }
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

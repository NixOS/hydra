mod connection;
pub mod models;

use std::str::FromStr as _;

pub use connection::{Connection, Transaction};
pub use sqlx::Error;

#[derive(Clone)]
pub struct Database {
    pool: sqlx::PgPool,
}

impl Database {
    pub async fn new(url: &str, max_connections: u32) -> Result<Self, sqlx::Error> {
        Ok(Self {
            pool: sqlx::postgres::PgPoolOptions::new()
                .max_connections(max_connections)
                .connect(url)
                .await?,
        })
    }

    pub async fn get(&self) -> Result<Connection, sqlx::Error> {
        let conn = self.pool.acquire().await?;
        Ok(Connection::new(conn))
    }

    pub fn reconfigure_pool(&self, url: &str) -> anyhow::Result<()> {
        // TODO: ability to change max_connections by dropping the pool and recreating it
        self.pool
            .set_connect_options(sqlx::postgres::PgConnectOptions::from_str(url)?);
        Ok(())
    }

    pub async fn listener(
        &self,
        channels: Vec<&str>,
    ) -> Result<
        impl futures::Stream<Item = Result<sqlx::postgres::PgNotification, sqlx::Error>> + Unpin,
        sqlx::Error,
    > {
        let mut listener = sqlx::postgres::PgListener::connect_with(&self.pool).await?;
        listener.listen_all(channels).await?;
        Ok(listener.into_stream())
    }
}

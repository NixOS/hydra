use std::collections::BTreeMap;

use sqlx::Acquire;

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

mod builds;
mod jobsets;
mod notify;
mod resolve;
mod steps;
#[cfg(test)]
mod test_helpers;

/// A pooled [`Connection`] or a [`Transaction`] on one. Both can run
/// single-statement queries. Writes that span several statements run
/// in a [`Transaction`] so they are atomic. Most are methods on it, and
/// `Connection::abort_build` opens its own.
#[derive(Debug)]
pub struct Handle<C> {
    conn: C,
}

pub type Connection = Handle<sqlx::pool::PoolConnection<sqlx::Postgres>>;
pub type Transaction<'a> = Handle<sqlx::PgTransaction<'a>>;

/// Reads that return store-path data also read the row's storeDir and
/// assert it matches the configured store dir, rather than silently
/// trusting that the whole DB belongs to this store.
fn check_store_dir(store_dir: &StoreDir, found: &str) -> crate::Result<()> {
    if store_dir.to_str() == found {
        Ok(())
    } else {
        Err(crate::DataError::StoreDirMismatch {
            expected: store_dir.to_str().to_owned(),
            found: found.to_owned(),
        }
        .into())
    }
}

/// Parse a store path out of a row, in whichever of the two formats it
/// is stored in: a converted row holds the basename and records its
/// store in storeDir, while one that `hydra-backfill-store-dirs` has not
/// reached yet holds the full path and a null storeDir.
pub fn parse_row_path(
    store_dir: &StoreDir,
    path: &str,
    row_store_dir: Option<&str>,
) -> crate::Result<StorePath> {
    match row_store_dir {
        Some(found) => {
            check_store_dir(store_dir, found)?;
            Ok(StorePath::from_base_path(path)?)
        }
        None => Ok(store_dir.parse(path)?),
    }
}

/// Both stored forms of a path, for lookups that have to find a row
/// whether or not it has been converted yet. Bound against `= ANY(...)`,
/// so the existing indexes on these columns still serve the lookup.
fn path_forms(store_dir: &StoreDir, path: &StorePath) -> Vec<String> {
    vec![path.to_string(), store_dir.display(path).to_string()]
}

impl<C: std::ops::DerefMut<Target = sqlx::PgConnection>> Handle<C> {
    /// Raw access to the underlying connection, for components whose
    /// schema knowledge deliberately lives outside this crate: they keep
    /// their own compile-time-checked queries next to the code that owns
    /// that slice of the schema, while still acquiring connections
    /// through [`Database::get`](crate::Database::get) and its retry.
    pub fn raw(&mut self) -> &mut sqlx::PgConnection {
        &mut self.conn
    }
}

impl Connection {
    #[must_use]
    pub(crate) const fn new(conn: sqlx::pool::PoolConnection<sqlx::Postgres>) -> Self {
        Self { conn }
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn begin_transaction(&mut self) -> crate::Result<Transaction<'_>> {
        Ok(Handle {
            conn: self.conn.begin().await?,
        })
    }
}

impl Transaction<'_> {
    #[tracing::instrument(skip(self), err)]
    pub async fn commit(self) -> crate::Result<()> {
        Ok(self.conn.commit().await?)
    }
}

/// Split outputs into the parallel `name` and `path` arrays that `UNNEST`
/// takes. The paths are basenames; the caller writes the store dir beside
/// them.
fn names_and_paths(outputs: &BTreeMap<OutputName, StorePath>) -> (Vec<String>, Vec<String>) {
    outputs
        .iter()
        .map(|(name, path)| (name.to_string(), path.to_string()))
        .unzip()
}

//! Read-only access to the local Nix store database.
//!
//! `HasPath` and `FetchRequisites` are pure reads, but going through the
//! nix-daemon makes them compete for pooled daemon connections with NAR
//! uploads, which hold a connection for minutes. Query the `SQLite` database
//! directly instead so reads never wait on the daemon.

use std::collections::BTreeSet;

use harmonia_store_path::{StoreDir, StorePath};
use harmonia_store_path_info::{UnkeyedValidPathInfo, ValidPathInfo};

fn decode_err<E: std::error::Error + Send + Sync + 'static>(e: E) -> sqlx::Error {
    sqlx::Error::Decode(Box::new(e))
}

/// Read-only pool on `/nix/var/nix/db/db.sqlite`.
#[derive(Debug, Clone)]
pub struct LocalNixDb {
    pool: sqlx::SqlitePool,
    store_dir: StoreDir,
}

impl LocalNixDb {
    pub async fn open(store_dir: StoreDir) -> Result<Self, sqlx::Error> {
        Self::open_at(store_dir, &Self::default_db_path()).await
    }

    /// Database location, honoring `NIX_STATE_DIR` like libnixstore so
    /// non-default Nix stores (e.g. the test harness) are found.
    fn default_db_path() -> String {
        let state_dir =
            std::env::var("NIX_STATE_DIR").unwrap_or_else(|_| "/nix/var/nix".to_string());
        format!("{state_dir}/db/db.sqlite")
    }

    pub async fn open_at(store_dir: StoreDir, path: &str) -> Result<Self, sqlx::Error> {
        let opts = sqlx::sqlite::SqliteConnectOptions::new()
            .filename(path)
            .read_only(true)
            // Long busy timeout like libnixstore, so a writer checkpointing
            // the WAL does not fail us with SQLITE_BUSY.
            .busy_timeout(std::time::Duration::from_hours(1));
        let pool = sqlx::sqlite::SqlitePoolOptions::new()
            .max_connections(4)
            .connect_with(opts)
            .await?;
        Ok(Self { pool, store_dir })
    }

    pub async fn is_valid_path(&self, path: &StorePath) -> Result<bool, sqlx::Error> {
        let full = self.store_dir.display(path).to_string();
        let row: Option<(i64,)> = sqlx::query_as("SELECT 1 FROM ValidPaths WHERE path = ?")
            .bind(full)
            .fetch_optional(&self.pool)
            .await?;
        Ok(row.is_some())
    }

    /// Query full path info, `None` if the path is not valid.
    pub async fn query_path_info(
        &self,
        path: &StorePath,
    ) -> Result<Option<ValidPathInfo>, sqlx::Error> {
        type Row = (
            i64,            // id
            String,         // hash
            i64,            // registrationTime
            Option<String>, // deriver
            Option<i64>,    // narSize
            Option<i32>,    // ultimate
            Option<String>, // sigs
            Option<String>, // ca
        );
        let full = self.store_dir.display(path).to_string();
        let row: Option<Row> = sqlx::query_as(
            "SELECT id, hash, registrationTime, deriver, narSize, ultimate, sigs, ca \
             FROM ValidPaths WHERE path = ?",
        )
        .bind(full)
        .fetch_optional(&self.pool)
        .await?;
        let Some((id, hash_str, reg_time, deriver_str, nar_size, ultimate, sigs_str, ca_str)) = row
        else {
            return Ok(None);
        };

        let nar_hash = hash_str
            .parse::<harmonia_utils_hash::fmt::Any<harmonia_store_path_info::NarHash>>()
            .map_err(decode_err)?
            .into_hash();
        let deriver = deriver_str
            .map(|s| self.store_dir.parse(&s))
            .transpose()
            .map_err(decode_err)?;
        let signatures = sigs_str
            .map(|s| {
                s.split_whitespace()
                    .filter_map(|sig| sig.parse().ok())
                    .collect()
            })
            .unwrap_or_default();
        let ca = ca_str.map(|s| s.parse()).transpose().map_err(decode_err)?;

        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT v.path FROM Refs r \
             JOIN ValidPaths v ON r.reference = v.id \
             WHERE r.referrer = ?",
        )
        .bind(id)
        .fetch_all(&self.pool)
        .await?;
        let references = rows
            .into_iter()
            .filter_map(|(p,)| self.store_dir.parse(&p).ok())
            .collect();

        Ok(Some(ValidPathInfo {
            path: path.clone(),
            info: UnkeyedValidPathInfo {
                deriver,
                nar_hash,
                references,
                registration_time: std::num::NonZero::new(reg_time),
                nar_size: nar_size.map_or(0, i64::cast_unsigned),
                ultimate: ultimate.unwrap_or(0) != 0,
                signatures,
                ca,
                store_dir: self.store_dir.clone(),
            },
        }))
    }

    /// Closure of `roots` with full path info, dependencies first.
    pub async fn query_closure_infos(
        &self,
        roots: Vec<StorePath>,
    ) -> Result<Vec<ValidPathInfo>, sqlx::Error> {
        let closure = self.query_closure(roots).await?;
        let mut infos = Vec::with_capacity(closure.len());
        for path in closure {
            // The path was valid during the walk; treat disappearance
            // (e.g. concurrent GC) as an error rather than skipping.
            let info = self
                .query_path_info(&path)
                .await?
                .ok_or_else(|| sqlx::Error::RowNotFound)?;
            infos.push(info);
        }
        Ok(infos)
    }

    async fn references(&self, path: &StorePath) -> Result<Vec<StorePath>, sqlx::Error> {
        let full = self.store_dir.display(path).to_string();
        let rows: Vec<(String,)> = sqlx::query_as(
            "SELECT v.path FROM Refs r \
             JOIN ValidPaths v ON r.reference = v.id \
             WHERE r.referrer = (SELECT id FROM ValidPaths WHERE path = ?)",
        )
        .bind(full)
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .filter_map(|(p,)| self.store_dir.parse(&p).ok())
            .collect())
    }

    /// Compute the closure of `roots`, dependencies before dependents.
    /// Invalid roots are skipped, matching the daemon-based closure walk.
    pub async fn query_closure(
        &self,
        roots: Vec<StorePath>,
    ) -> Result<Vec<StorePath>, sqlx::Error> {
        enum Frame {
            Enter(StorePath),
            Exit(StorePath),
        }
        let mut seen: BTreeSet<StorePath> = BTreeSet::new();
        let mut sorted = Vec::new();
        // Iterative DFS; post-order emits dependencies before dependents.
        let mut stack: Vec<Frame> = roots.into_iter().map(Frame::Enter).collect();
        while let Some(frame) = stack.pop() {
            match frame {
                Frame::Enter(p) => {
                    if !seen.insert(p.clone()) {
                        continue;
                    }
                    if !self.is_valid_path(&p).await? {
                        continue;
                    }
                    let refs = self.references(&p).await?;
                    stack.push(Frame::Exit(p.clone()));
                    for r in refs {
                        if r != p && !seen.contains(&r) {
                            stack.push(Frame::Enter(r));
                        }
                    }
                }
                Frame::Exit(p) => sorted.push(p),
            }
        }
        Ok(sorted)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    async fn test_db(dir: &std::path::Path) -> LocalNixDb {
        let path = dir.join("db.sqlite");
        let opts = sqlx::sqlite::SqliteConnectOptions::new()
            .filename(&path)
            .create_if_missing(true);
        let pool = sqlx::SqlitePool::connect_with(opts).await.unwrap();
        sqlx::raw_sql(
            "CREATE TABLE ValidPaths (
                 id integer primary key autoincrement not null,
                 path text unique not null,
                 hash text not null,
                 registrationTime integer not null,
                 deriver text,
                 narSize integer,
                 ultimate integer,
                 sigs text,
                 ca text
             );
             CREATE TABLE Refs (
                 referrer integer not null,
                 reference integer not null
             );
             INSERT INTO ValidPaths (id, path, hash, registrationTime, narSize) VALUES
               (1, '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a',
                'sha256:0000000000000000000000000000000000000000000000000000000000000000', 0, 120),
               (2, '/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b',
                'sha256:0000000000000000000000000000000000000000000000000000000000000000', 0, 240),
               (3, '/nix/store/cccccccccccccccccccccccccccccccc-c',
                'sha256:0000000000000000000000000000000000000000000000000000000000000000', 0, 360);
             -- a depends on b, b depends on c
             INSERT INTO Refs VALUES (1, 2), (2, 3);",
        )
        .execute(&pool)
        .await
        .unwrap();
        drop(pool);
        LocalNixDb::open_at(StoreDir::default(), path.to_str().unwrap())
            .await
            .unwrap()
    }

    fn sp(s: &str) -> StorePath {
        s.parse().unwrap()
    }

    #[tokio::test]
    async fn closure_is_dependencies_first() {
        let dir = tempfile::tempdir().unwrap();
        let db = test_db(dir.path()).await;

        assert!(
            db.is_valid_path(&sp("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a"))
                .await
                .unwrap()
        );
        assert!(
            !db.is_valid_path(&sp("dddddddddddddddddddddddddddddddd-d"))
                .await
                .unwrap()
        );

        let closure = db
            .query_closure(vec![sp("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a")])
            .await
            .unwrap();
        let names: Vec<_> = closure.iter().map(|p| p.name().to_string()).collect();
        assert_eq!(names, ["c", "b", "a"]);

        // invalid roots are skipped
        let closure = db
            .query_closure(vec![sp("dddddddddddddddddddddddddddddddd-d")])
            .await
            .unwrap();
        assert!(closure.is_empty());

        let infos = db
            .query_closure_infos(vec![sp("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a")])
            .await
            .unwrap();
        assert_eq!(infos.len(), 3);
        assert_eq!(infos[0].info.nar_size, 360); // c, dependencies first
        assert_eq!(
            infos[2].info.references,
            [sp("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b")].into()
        );
    }
}

//! Read-only access to the local Nix store database.
//!
//! `HasPath` and `FetchRequisites` are pure reads, but going through the
//! nix-daemon makes them compete for pooled daemon connections with NAR
//! uploads, which hold a connection for minutes. Query the `SQLite` database
//! directly instead so reads never wait on the daemon.

use std::collections::BTreeSet;

use harmonia_store_path::{StoreDir, StorePath};

/// Read-only pool on `/nix/var/nix/db/db.sqlite`.
#[derive(Debug, Clone)]
pub struct LocalNixDb {
    pool: sqlx::SqlitePool,
    store_dir: StoreDir,
}

impl LocalNixDb {
    pub async fn open(store_dir: StoreDir) -> Result<Self, sqlx::Error> {
        Self::open_at(store_dir, "/nix/var/nix/db/db.sqlite").await
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
                 registrationTime integer not null
             );
             CREATE TABLE Refs (
                 referrer integer not null,
                 reference integer not null
             );
             INSERT INTO ValidPaths (id, path, hash, registrationTime) VALUES
               (1, '/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-a', 'sha256:0', 0),
               (2, '/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-b', 'sha256:0', 0),
               (3, '/nix/store/cccccccccccccccccccccccccccccccc-c', 'sha256:0', 0);
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
    }
}

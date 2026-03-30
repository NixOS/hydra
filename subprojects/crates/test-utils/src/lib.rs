//! Reusable test infrastructure for hydra Rust crates.
//!
//! Spins up an ephemeral PostgreSQL instance per test (like Perl's
//! `Test::PostgreSQL`), loads the hydra schema, and hands back a
//! [`sqlx::PgPool`]. Cleaned up automatically on drop.

use std::path::PathBuf;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

/// An Ephemeral PostgreSQL instance.
///
/// Each instance gets its own data directory and TCP port so tests can
/// run in parallel without interference.
#[derive(Debug)]
pub struct TestPg {
    dir: PathBuf,
    port: u16,
}

static COUNTER: AtomicU32 = AtomicU32::new(0);

impl TestPg {
    /// Spin up a fresh PG instance and load the hydra schema.
    pub async fn new() -> (Self, sqlx::PgPool) {
        let id = COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("hydra-test-pg-{}-{id}", std::process::id()));
        let _ = fs_err::remove_dir_all(&dir);
        fs_err::create_dir_all(&dir).unwrap();

        assert!(
            Command::new("initdb")
                .args([
                    "-D",
                    dir.to_str().unwrap(),
                    "--no-locale",
                    "-E",
                    "UTF8",
                    "-A",
                    "trust",
                ])
                .output()
                .unwrap()
                .status
                .success(),
            "initdb failed — is postgresql in PATH?"
        );

        // Grab a free port from the OS.
        let port = {
            let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };

        assert!(
            Command::new("pg_ctl")
                .args([
                    "-D",
                    dir.to_str().unwrap(),
                    "-l",
                    dir.join("log").to_str().unwrap(),
                    "-o",
                    &format!(
                        "-k {} -p {port} -c listen_addresses=127.0.0.1",
                        dir.display()
                    ),
                    "start",
                ])
                .output()
                .unwrap()
                .status
                .success(),
            "pg_ctl start failed"
        );

        assert!(
            Command::new("createdb")
                .args(["-h", dir.to_str().unwrap(), "-p", &port.to_string(), "test"])
                .output()
                .unwrap()
                .status
                .success(),
            "createdb failed"
        );

        let pg = Self { dir, port };
        let pool = sqlx::PgPool::connect(&pg.url()).await.unwrap();
        let schema = include_str!("../../../hydra/sql/hydra.sql");
        sqlx::raw_sql(schema).execute(&pool).await.unwrap();
        (pg, pool)
    }

    /// Connection URL for this instance.
    pub fn url(&self) -> String {
        format!(
            "postgresql://localhost:{}/test?host={}",
            self.port,
            self.dir.display()
        )
    }
}

impl Drop for TestPg {
    fn drop(&mut self) {
        let _ = Command::new("pg_ctl")
            .args(["-D", self.dir.to_str().unwrap(), "-m", "immediate", "stop"])
            .output();
        let _ = fs_err::remove_dir_all(&self.dir);
    }
}

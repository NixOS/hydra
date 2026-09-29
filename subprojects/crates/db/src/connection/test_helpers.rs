#![allow(clippy::unwrap_used)]

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use crate::Connection;
use crate::models::{BuildID, BuildStatus};

pub(super) fn test_store_dir() -> StoreDir {
    StoreDir::new("/nix/store").unwrap()
}

pub(super) fn sp(s: &str) -> StorePath {
    format!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0-{s}")
        .parse()
        .unwrap()
}

pub(super) fn on(s: &str) -> OutputName {
    s.parse().unwrap()
}

pub(super) async fn setup() -> (test_utils::TestPg, Connection) {
    let (pg, pool) = test_utils::TestPg::new().await;
    let conn = replica_conn(&pool).await;
    (pg, conn)
}

pub(super) async fn insert_step(
    conn: &mut Connection,
    build: BuildID,
    stepnr: i32,
    drv_path: &StorePath,
) {
    insert_step_with_status(conn, build, stepnr, drv_path, BuildStatus::Success, None).await;
}

pub(super) async fn insert_step_with_status(
    conn: &mut Connection,
    build: BuildID,
    stepnr: i32,
    drv_path: &StorePath,
    status: BuildStatus,
    resolved_drv_path: Option<&StorePath>,
) {
    let sd = test_store_dir();
    sqlx::query!(
        "INSERT INTO BuildSteps (build, stepnr, type, busy, drvPath, status, resolvedDrvPath) VALUES ($1, $2, 0, 0, $3, $4, $5)",
        build,
        stepnr,
        sd.display(drv_path).to_string(),
        status as i32,
        resolved_drv_path.map(ToString::to_string),
    )
        .execute(&mut *conn.conn)
        .await
        .unwrap();
}

pub(super) async fn insert_output(
    conn: &mut Connection,
    build: BuildID,
    stepnr: i32,
    name: &str,
    path: &StorePath,
) {
    sqlx::query!(
        "INSERT INTO BuildStepOutputs (build, stepnr, name, path) VALUES ($1, $2, $3, $4)",
        build,
        stepnr,
        name,
        test_store_dir().display(path).to_string(),
    )
    .execute(&mut *conn.conn)
    .await
    .unwrap();
}

pub(super) async fn replica_conn(pool: &sqlx::PgPool) -> Connection {
    let mut conn = Connection::new(pool.acquire().await.unwrap());
    sqlx::raw_sql("SET session_replication_role = 'replica';")
        .execute(&mut *conn.conn)
        .await
        .unwrap();
    conn
}

//! Tests for the drv-in-db schema (upgrade-86).
//!
//! Validates that the tables load, CHECK constraints enforce the
//! outputType/hasStructuredAttrs composite-FK pattern, and basic CRUD works.

#![allow(clippy::unwrap_used)]

async fn setup() -> (test_utils::TestPg, sqlx::PgPool) {
    test_utils::TestPg::new_drv_in_db().await
}

// -- Schema loads --

#[tokio::test]
async fn drv_schema_loads() {
    let (_pg, pool) = setup().await;
    let row: (i64,) = sqlx::query_as(
        "SELECT count(*) FROM information_schema.tables
         WHERE table_schema = 'public' AND table_name LIKE 'derivation%'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(row.0, 6, "expected 6 derivation tables, got {}", row.0);
}

// -- Derivations insert --

async fn insert_drv(pool: &sqlx::PgPool, path: &str, output_type: i32, has_sa: bool) -> i32 {
    let row: (i32,) = sqlx::query_as(
        "INSERT INTO Derivations (path, platform, builder, args, outputType, hasStructuredAttrs)
         VALUES ($1, 'x86_64-linux', '/bin/sh', '{-e,echo}', $2, $3)
         RETURNING id",
    )
    .bind(path)
    .bind(output_type)
    .bind(has_sa)
    .fetch_one(pool)
    .await
    .unwrap();
    row.0
}

// -- outputType CHECK constraints on DerivationOutputs --

#[tokio::test]
async fn output_input_addressed_accepts_valid() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 0, false).await;
    sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType, path)
         VALUES ($1, 'out', 0, '/nix/store/bbb-result')",
    )
    .bind(drv)
    .execute(&pool)
    .await
    .unwrap();
}

#[tokio::test]
async fn output_input_addressed_rejects_hash() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 0, false).await;
    let result = sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType, path, hashAlgo)
         VALUES ($1, 'out', 0, '/nix/store/bbb', 'sha256')",
    )
    .bind(drv)
    .execute(&pool)
    .await;
    assert!(result.is_err(), "outputType=0 should reject hashAlgo");
}

#[tokio::test]
async fn output_ca_fixed_accepts_valid() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 1, false).await;
    sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType, method, hashAlgo, hash)
         VALUES ($1, 'out', 1, 'r:sha256', 'sha256', 'sha256-abc123')",
    )
    .bind(drv)
    .execute(&pool)
    .await
    .unwrap();
}

#[tokio::test]
async fn output_ca_fixed_rejects_missing_hash() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 1, false).await;
    let result = sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType, method, hashAlgo)
         VALUES ($1, 'out', 1, 'r:sha256', 'sha256')",
    )
    .bind(drv)
    .execute(&pool)
    .await;
    assert!(result.is_err(), "outputType=1 should require hash");
}

#[tokio::test]
async fn output_deferred_accepts_valid() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 3, false).await;
    sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType)
         VALUES ($1, 'out', 3)",
    )
    .bind(drv)
    .execute(&pool)
    .await
    .unwrap();
}

#[tokio::test]
async fn output_deferred_rejects_path() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 3, false).await;
    let result = sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType, path)
         VALUES ($1, 'out', 3, '/nix/store/bbb')",
    )
    .bind(drv)
    .execute(&pool)
    .await;
    assert!(result.is_err(), "outputType=3 should reject path");
}

#[tokio::test]
async fn output_type_mismatch_rejected() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 0, false).await;
    // Parent has outputType=0, try inserting outputType=3
    let result = sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType)
         VALUES ($1, 'out', 3)",
    )
    .bind(drv)
    .execute(&pool)
    .await;
    assert!(
        result.is_err(),
        "composite FK should reject mismatched outputType"
    );
}

// -- Composite FK for structured attrs --

#[tokio::test]
async fn structured_attrs_allowed_when_flag_set() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 3, true).await;
    sqlx::query(
        "INSERT INTO DerivationStructuredAttrs (drv, hasStructuredAttrs, key, value)
         VALUES ($1, true, 'foo', '\"bar\"')",
    )
    .bind(drv)
    .execute(&pool)
    .await
    .unwrap();
}

#[tokio::test]
async fn structured_attrs_rejected_when_flag_unset() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 3, false).await;
    let result = sqlx::query(
        "INSERT INTO DerivationStructuredAttrs (drv, hasStructuredAttrs, key, value)
         VALUES ($1, true, 'foo', '\"bar\"')",
    )
    .bind(drv)
    .execute(&pool)
    .await;
    assert!(
        result.is_err(),
        "composite FK should reject structured attrs when hasStructuredAttrs=false"
    );
}

// -- Cascade delete --

#[tokio::test]
async fn cascade_deletes_children() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 0, false).await;

    sqlx::query(
        "INSERT INTO DerivationOutputs (drv, id, outputType, path)
         VALUES ($1, 'out', 0, '/nix/store/bbb')",
    )
    .bind(drv)
    .execute(&pool)
    .await
    .unwrap();

    sqlx::query("INSERT INTO DerivationInputSrcs (drv, src) VALUES ($1, '/nix/store/ccc')")
        .bind(drv)
        .execute(&pool)
        .await
        .unwrap();

    sqlx::query(
        "INSERT INTO DerivationEnv (drv, key, value) VALUES ($1, 'name', 'test')",
    )
    .bind(drv)
    .execute(&pool)
    .await
    .unwrap();

    sqlx::query("DELETE FROM Derivations WHERE id = $1")
        .bind(drv)
        .execute(&pool)
        .await
        .unwrap();

    let count: (i64,) = sqlx::query_as("SELECT count(*) FROM DerivationOutputs WHERE drv = $1")
        .bind(drv)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count.0, 0);

    let count: (i64,) = sqlx::query_as("SELECT count(*) FROM DerivationInputSrcs WHERE drv = $1")
        .bind(drv)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count.0, 0);

    let count: (i64,) = sqlx::query_as("SELECT count(*) FROM DerivationEnv WHERE drv = $1")
        .bind(drv)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count.0, 0);
}

// -- DerivationInputs jsonb check --

#[tokio::test]
async fn inputs_rejects_non_array_outputs() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 0, false).await;
    let result = sqlx::query(
        r#"INSERT INTO DerivationInputs (drv, path, outputs)
         VALUES ($1, '/nix/store/dep.drv', '{"not": "array"}')"#,
    )
    .bind(drv)
    .execute(&pool)
    .await;
    assert!(result.is_err(), "outputs must be a JSON array");
}

#[tokio::test]
async fn inputs_accepts_array_outputs() {
    let (_pg, pool) = setup().await;
    let drv = insert_drv(&pool, "/nix/store/aaa.drv", 0, false).await;
    sqlx::query(
        r#"INSERT INTO DerivationInputs (drv, path, outputs)
         VALUES ($1, '/nix/store/dep.drv', '["out", "dev"]')"#,
    )
    .bind(drv)
    .execute(&pool)
    .await
    .unwrap();
}

// -- Duplicate path rejection --

#[tokio::test]
async fn duplicate_drv_path_rejected() {
    let (_pg, pool) = setup().await;
    insert_drv(&pool, "/nix/store/aaa.drv", 0, false).await;
    let result = sqlx::query(
        "INSERT INTO Derivations (path, platform, builder, outputType)
         VALUES ('/nix/store/aaa.drv', 'x86_64-linux', '/bin/sh', 0)",
    )
    .execute(&pool)
    .await;
    assert!(result.is_err(), "duplicate path should be rejected");
}

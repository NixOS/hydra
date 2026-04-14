//! Tests for insert_derivation: decomposing Derivation structs into the 6 drv-in-db tables.

#![allow(clippy::unwrap_used)]

use std::collections::BTreeSet;

use harmonia_store_core::derivation::{Derivation, DerivationOutput};
use harmonia_store_core::derived_path::SingleDerivedPath;
use harmonia_store_core::store_path::{StoreDir, StorePath};

fn store_dir() -> StoreDir {
    StoreDir::new("/nix/store").unwrap()
}

fn sp(hash_name: &str) -> StorePath {
    store_dir()
        .parse::<StorePath>(&format!("/nix/store/{hash_name}"))
        .unwrap()
}

fn make_drv(
    outputs: Vec<(&str, DerivationOutput)>,
    inputs: BTreeSet<SingleDerivedPath>,
    env: Vec<(&str, &str)>,
) -> Derivation {
    use harmonia_store_core::ByteString;

    let output_map = outputs
        .into_iter()
        .map(|(k, v)| (k.parse().unwrap(), v))
        .collect();
    let env_map = env
        .into_iter()
        .map(|(k, v)| {
            (
                ByteString::from(k.to_owned().into_bytes()),
                ByteString::from(v.to_owned().into_bytes()),
            )
        })
        .collect();
    Derivation {
        name: "test-drv".parse().unwrap(),
        outputs: output_map,
        inputs,
        platform: ByteString::from(b"x86_64-linux" as &[u8]),
        builder: ByteString::from(b"/bin/sh" as &[u8]),
        args: vec![
            ByteString::from(b"-e" as &[u8]),
            ByteString::from(b"echo hello" as &[u8]),
        ],
        env: env_map,
        structured_attrs: None,
    }
}

async fn setup() -> (test_utils::TestPg, sqlx::PgPool) {
    test_utils::TestPg::new_drv_in_db().await
}

#[tokio::test]
async fn input_addressed_drv() {
    let (pg, pool) = setup().await;
    let sd = store_dir();
    let mut conn = db::Connection::new(pool.acquire().await.unwrap());

    let out_path = sp("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-result");
    let drv = make_drv(
        vec![("out", DerivationOutput::InputAddressed(out_path))],
        BTreeSet::new(),
        vec![("name", "test")],
    );

    let drv_id = conn
        .insert_derivation(
            "/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-test.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap()
        .unwrap();

    let verify = sqlx::PgPool::connect(&pg.url()).await.unwrap();

    let row: (String, String, i32) = sqlx::query_as(
        "SELECT platform, builder, outputType FROM Derivations WHERE id = $1",
    )
    .bind(drv_id)
    .fetch_one(&verify)
    .await
    .unwrap();
    assert_eq!(row.0, "x86_64-linux");
    assert_eq!(row.1, "/bin/sh");
    assert_eq!(row.2, 0);

    let out: (String, Option<String>, Option<String>) = sqlx::query_as(
        "SELECT id, path, hash FROM DerivationOutputs WHERE drv = $1",
    )
    .bind(drv_id)
    .fetch_one(&verify)
    .await
    .unwrap();
    assert_eq!(out.0, "out");
    assert!(out.1.unwrap().contains("result"));
    assert!(out.2.is_none());

    let env: (String,) = sqlx::query_as(
        "SELECT value FROM DerivationEnv WHERE drv = $1 AND key = 'name'",
    )
    .bind(drv_id)
    .fetch_one(&verify)
    .await
    .unwrap();
    assert_eq!(env.0, "test");
}

#[tokio::test]
async fn deferred_drv() {
    let (_pg, pool) = setup().await;
    let sd = store_dir();
    let mut conn = db::Connection::new(pool.acquire().await.unwrap());

    let drv = make_drv(
        vec![("out", DerivationOutput::Deferred)],
        BTreeSet::new(),
        vec![],
    );

    let id = conn
        .insert_derivation(
            "/nix/store/cccccccccccccccccccccccccccccccc-deferred.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap()
        .unwrap();

    let row: (i32, Option<String>, Option<String>, Option<String>) = sqlx::query_as(
        "SELECT outputType, path, method, hash FROM DerivationOutputs WHERE drv = $1",
    )
    .bind(id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(row.0, 3);
    assert!(row.1.is_none());
    assert!(row.2.is_none());
    assert!(row.3.is_none());
}

#[tokio::test]
async fn ca_floating_drv() {
    let (_pg, pool) = setup().await;
    let sd = store_dir();
    let mut conn = db::Connection::new(pool.acquire().await.unwrap());

    use harmonia_store_core::store_path::ContentAddressMethodAlgorithm;
    use harmonia_utils_hash::Algorithm;

    let cam = ContentAddressMethodAlgorithm::Recursive(Algorithm::SHA256);
    let drv = make_drv(
        vec![("out", DerivationOutput::CAFloating(cam))],
        BTreeSet::new(),
        vec![],
    );

    let id = conn
        .insert_derivation(
            "/nix/store/dddddddddddddddddddddddddddddddd-cafloat.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap()
        .unwrap();

    let row: (i32, Option<String>, Option<String>, Option<String>) = sqlx::query_as(
        "SELECT outputType, method, hashAlgo, hash FROM DerivationOutputs WHERE drv = $1",
    )
    .bind(id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(row.0, 2);
    assert_eq!(row.1.unwrap(), "r:sha256");
    assert_eq!(row.2.unwrap(), "sha256");
    assert!(row.3.is_none());
}

#[tokio::test]
async fn duplicate_path_returns_none() {
    let (_pg, pool) = setup().await;
    let sd = store_dir();
    let mut conn = db::Connection::new(pool.acquire().await.unwrap());

    let drv = make_drv(
        vec![("out", DerivationOutput::Deferred)],
        BTreeSet::new(),
        vec![],
    );

    let first = conn
        .insert_derivation(
            "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-dup.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap();
    assert!(first.is_some());

    let second = conn
        .insert_derivation(
            "/nix/store/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee-dup.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap();
    assert!(second.is_none(), "duplicate insert should return None");
}

#[tokio::test]
async fn env_vars_round_trip() {
    let (_pg, pool) = setup().await;
    let sd = store_dir();
    let mut conn = db::Connection::new(pool.acquire().await.unwrap());

    let env = vec![
        ("name", "my-package"),
        ("system", "x86_64-linux"),
        ("src", "/nix/store/fff-source"),
    ];
    let drv = make_drv(
        vec![("out", DerivationOutput::Deferred)],
        BTreeSet::new(),
        env,
    );

    let id = conn
        .insert_derivation(
            "/nix/store/gggggggggggggggggggggggggggggggg-envtest.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap()
        .unwrap();

    let rows: Vec<(String, String)> = sqlx::query_as(
        "SELECT key, value FROM DerivationEnv WHERE drv = $1 ORDER BY key",
    )
    .bind(id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[0], ("name".into(), "my-package".into()));
    assert_eq!(rows[1], ("src".into(), "/nix/store/fff-source".into()));
    assert_eq!(rows[2], ("system".into(), "x86_64-linux".into()));
}

#[tokio::test]
async fn inputs_stored() {
    let (_pg, pool) = setup().await;
    let sd = store_dir();
    let mut conn = db::Connection::new(pool.acquire().await.unwrap());

    let src = sp("hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-source");
    let mut inputs = BTreeSet::new();
    inputs.insert(SingleDerivedPath::Opaque(src));

    let drv = make_drv(vec![("out", DerivationOutput::Deferred)], inputs, vec![]);

    let id = conn
        .insert_derivation(
            "/nix/store/iiiiiiiiiiiiiiiiiiiiiiiiiiiiiiii-withsrc.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap()
        .unwrap();

    let rows: Vec<(String,)> =
        sqlx::query_as("SELECT path FROM DerivationInputs WHERE drv = $1")
            .bind(id)
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(rows.len(), 1);
    assert!(rows[0].0.contains("source"));
}

#[tokio::test]
async fn structured_attrs_stored() {
    let (_pg, pool) = setup().await;
    let sd = store_dir();
    let mut conn = db::Connection::new(pool.acquire().await.unwrap());

    use harmonia_store_core::derivation::StructuredAttrs;

    let mut attrs = serde_json::Map::new();
    attrs.insert("allowedReferences".into(), serde_json::json!([]));
    attrs.insert("version".into(), serde_json::json!("1.0"));

    let mut drv = make_drv(
        vec![("out", DerivationOutput::Deferred)],
        BTreeSet::new(),
        vec![],
    );
    drv.structured_attrs = Some(StructuredAttrs { attrs });

    let id = conn
        .insert_derivation(
            "/nix/store/jjjjjjjjjjjjjjjjjjjjjjjjjjjjjjjj-sa.drv",
            &drv,
            &sd,
        )
        .await
        .unwrap()
        .unwrap();

    let sa_flag: (bool,) = sqlx::query_as(
        "SELECT hasStructuredAttrs FROM Derivations WHERE id = $1",
    )
    .bind(id)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(sa_flag.0);

    let rows: Vec<(String, serde_json::Value)> = sqlx::query_as(
        "SELECT key, value FROM DerivationStructuredAttrs WHERE drv = $1 ORDER BY key",
    )
    .bind(id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].0, "allowedReferences");
    assert_eq!(rows[1].0, "version");
    assert_eq!(rows[1].1, serde_json::json!("1.0"));
}

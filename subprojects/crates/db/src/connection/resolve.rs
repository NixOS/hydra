use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use super::{Handle, parse_row_path};

impl<C: std::ops::DerefMut<Target = sqlx::PgConnection>> Handle<C> {
    /// Resolve output paths for derivation chains via `buildstepoutputs`.
    ///
    /// Each entry is `(root_drv_path, &[output_name, ...])` representing a
    /// chain like `root.drv^out1^out2`. The recursive CTE walks the chain:
    /// look up `root.drv`'s `out1` output to get an intermediate drv path,
    /// then look up that drv's `out2`, etc. Returns the final resolved path
    /// for each chain (or `None` if any step fails).
    ///
    /// This matches drv paths in their converted (basename) form only, so
    /// while `hydra-backfill-store-dirs` is running it simply will not
    /// find steps that are still stored as full paths, and reports them
    /// as unresolved. Content-addressed builds are expected to be
    /// degraded for the duration rather than have this query carry a
    /// second matching form through its recursion.
    ///
    /// # Panics
    ///
    /// Panics if the SQL `ordinality` column is negative (should never happen).
    pub async fn resolve_drv_output_chains(
        &mut self,
        store_dir: &StoreDir,
        chains: &[(&StorePath, &[&OutputName])],
    ) -> crate::Result<Vec<Option<StorePath>>> {
        if chains.is_empty() {
            return Ok(Vec::new());
        }

        // We pack as JSON here since sqlx can't bind `text[][]` directly.
        let json_input = serde_json::Value::Array(
            chains
                .iter()
                .map(|(root, outputs)| {
                    serde_json::json!({
                        "root": root.to_string(),
                        "chain": outputs.iter().map(AsRef::as_ref).collect::<Vec<&str>>(),
                    })
                })
                .collect(),
        );

        let rows = sqlx::query!(
            r#"
            WITH RECURSIVE input AS (
                SELECT (ordinality)::int AS idx,
                       elem->>'root' AS drv,
                       ARRAY(SELECT jsonb_array_elements_text(elem->'chain')) AS chain
                FROM jsonb_array_elements($1::jsonb)
                    WITH ORDINALITY AS t(elem, ordinality)
            ),
            resolve(idx, drv_path, drv_storedir, step) AS (
                SELECT idx, drv, NULL::text, 1 FROM input

                UNION ALL

                SELECT r.idx, sub.path, sub.storedir, r.step + 1
                FROM resolve r
                JOIN input i ON i.idx = r.idx
                CROSS JOIN LATERAL (
                    SELECT o.path, o.storedir
                    FROM buildsteps s
                    -- If this step was resolved, look up outputs from
                    -- the resolved drv's successful buildstep instead.
                    LEFT JOIN buildsteps sr
                        ON sr.drvPath = s.resolvedDrvPath
                        AND sr.status = 0
                    JOIN buildstepoutputs o
                        ON o.build = COALESCE(sr.build, s.build)
                        AND o.stepnr = COALESCE(sr.stepnr, s.stepnr)
                    WHERE s.drvPath = r.drv_path
                      AND o.name = i.chain[r.step]
                      AND o.path IS NOT NULL
                      AND (s.status = 0 OR s.status = 13)
                    -- `+ 0`: otherwise the planner walks buildsteps_pkey
                    -- backwards instead of using IndexBuildStepsOnDrvPath.
                    ORDER BY s.build + 0 DESC
                    LIMIT 1
                ) sub
                WHERE r.step <= array_length(i.chain, 1)
                  AND r.drv_path IS NOT NULL
            )
            SELECT i.idx AS "idx!", r.drv_path, r.drv_storedir
            FROM input i
            LEFT JOIN resolve r
                ON r.idx = i.idx
                AND r.step = array_length(i.chain, 1) + 1
            ORDER BY i.idx
            "#,
            json_input,
        )
        .fetch_all(&mut *self.conn)
        .await?;

        let mut results = vec![None; chains.len()];
        for row in rows {
            let i = usize::try_from(row.idx - 1)?;
            results[i] = row
                .drv_path
                .map(|p| parse_row_path(store_dir, &p, row.drv_storedir.as_deref()))
                .transpose()?;
        }
        Ok(results)
    }

    /// Look up a single output of a derivation from the most recent
    /// successful buildstep.
    pub async fn resolve_drv_output(
        &mut self,
        store_dir: &StoreDir,
        drv_path: &StorePath,
        output_name: &OutputName,
    ) -> crate::Result<Option<StorePath>> {
        let drv_display = drv_path.to_string();
        let output_name_str: &str = output_name.as_ref();
        let row = sqlx::query!(
            r#"SELECT o.path AS "path!", o.storedir
              FROM buildsteps s
              JOIN buildstepoutputs o
                  ON s.build = o.build AND s.stepnr = o.stepnr
              WHERE s.drvPath = $1
                AND o.name = $2
                AND o.path IS NOT NULL
                AND s.status = 0
              -- `+ 0`: see resolve_drv_output_chains.
              ORDER BY s.build + 0 DESC
              LIMIT 1"#,
            drv_display,
            output_name_str,
        )
        .fetch_optional(&mut *self.conn)
        .await?;

        row.map(|r| parse_row_path(store_dir, &r.path, r.storedir.as_deref()))
            .transpose()
    }
}

#[cfg(test)]
mod tests {
    use crate::Connection;
    use crate::connection::test_helpers::{
        insert_output, insert_step, insert_step_with_status, on, setup, sp, test_store_dir,
    };
    use crate::models::BuildStatus;

    #[tokio::test]
    async fn resolve_depth_1() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("result")).await;

        let results = conn
            .resolve_drv_output_chains(&test_store_dir(), &[(&sp("foo.drv"), &[&on("out")])])
            .await
            .unwrap();
        assert_eq!(results, vec![Some(sp("result"))]);
    }

    /// Rows written before schema version 89 hold a full path and a null
    /// storeDir. Until `hydra-backfill-store-dirs` converts them, lookups
    /// have to find them and reads have to parse them.
    #[tokio::test]
    async fn finds_and_parses_unconverted_rows() {
        async fn insert_unconverted(conn: &mut Connection, build: i32, drv: &str, out: &str) {
            let sd = test_store_dir();
            sqlx::query(
                "INSERT INTO BuildSteps (build, stepnr, type, busy, drvPath, storeDir, status) \
                 VALUES ($1, 1, 0, 0, $2, NULL, 0)",
            )
            .bind(build)
            .bind(sd.display(&sp(drv)).to_string())
            .execute(&mut *conn.conn)
            .await
            .unwrap();
            sqlx::query(
                "INSERT INTO BuildStepOutputs (build, stepnr, name, path, storeDir) \
                 VALUES ($1, 1, 'out', $2, NULL)",
            )
            .bind(build)
            .bind(sd.display(&sp(out)).to_string())
            .execute(&mut *conn.conn)
            .await
            .unwrap();
        }

        let (_pg, mut conn) = setup().await;
        insert_unconverted(&mut conn, 1, "legacy.drv", "legacy-out").await;
        // A converted row alongside it, to prove both are visible at once.
        insert_step(&mut conn, 2, 1, &sp("converted.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("converted-out")).await;

        let mut tx = conn.begin_transaction().await.unwrap();
        for (drv, out) in [
            ("legacy.drv", "legacy-out"),
            ("converted.drv", "converted-out"),
        ] {
            let outputs = tx
                .find_build_step_outputs(&test_store_dir(), &sp(drv))
                .await
                .unwrap();
            assert_eq!(
                outputs.get(&on("out")),
                Some(&sp(out)),
                "{drv} should resolve to {out} regardless of stored format"
            );
        }
    }

    #[tokio::test]
    async fn resolve_depth_2() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("bar.drv")).await;
        insert_step(&mut conn, 2, 1, &sp("bar.drv")).await;
        insert_output(&mut conn, 2, 1, "dev", &sp("final")).await;

        let results = conn
            .resolve_drv_output_chains(
                &test_store_dir(),
                &[(&sp("foo.drv"), &[&on("out"), &on("dev")])],
            )
            .await
            .unwrap();
        assert_eq!(results, vec![Some(sp("final"))]);
    }

    #[tokio::test]
    async fn resolve_batch() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("foo-out")).await;
        insert_step(&mut conn, 2, 1, &sp("bar.drv")).await;
        insert_output(&mut conn, 2, 1, "lib", &sp("bar-lib")).await;

        let results = conn
            .resolve_drv_output_chains(
                &test_store_dir(),
                &[
                    (&sp("foo.drv"), &[&on("out")]),
                    (&sp("bar.drv"), &[&on("lib")]),
                ],
            )
            .await
            .unwrap();
        assert_eq!(results, vec![Some(sp("foo-out")), Some(sp("bar-lib")),]);
    }

    #[tokio::test]
    async fn resolve_missing() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("result")).await;

        let results = conn
            .resolve_drv_output_chains(
                &test_store_dir(),
                &[
                    (&sp("foo.drv"), &[&on("out")]),
                    (&sp("nonexistent.drv"), &[&on("out")]),
                ],
            )
            .await
            .unwrap();
        assert_eq!(results, vec![Some(sp("result")), None]);
    }

    #[tokio::test]
    async fn resolve_empty() {
        let (_pg, mut conn) = setup().await;
        let results = conn
            .resolve_drv_output_chains(&test_store_dir(), &[])
            .await
            .unwrap();
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn resolve_picks_latest_build() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_output(
            &mut conn,
            1,
            1,
            "out",
            &sp("aldaldaldaldaldaldaldaldaldaldal-result"),
        )
        .await;
        insert_step(&mut conn, 5, 1, &sp("foo.drv")).await;
        insert_output(
            &mut conn,
            5,
            1,
            "out",
            &sp("nawnawnawnawnawnawnawnawnawnawna-result"),
        )
        .await;

        let results = conn
            .resolve_drv_output_chains(&test_store_dir(), &[(&sp("foo.drv"), &[&on("out")])])
            .await
            .unwrap();
        assert_eq!(
            results,
            vec![Some(sp("nawnawnawnawnawnawnawnawnawnawna-result"))]
        );
    }

    /// A step that was resolved (status=13) with `resolvedDrvPath` pointing
    /// to a different drv whose successful buildstep has the outputs.
    #[tokio::test]
    async fn resolve_through_resolved_step() {
        let (_pg, mut conn) = setup().await;

        // Step 1: unresolved ca-depending-on-ca.drv, status=Resolved(13),
        // resolvedDrvPath points to the resolved drv
        insert_step_with_status(
            &mut conn,
            1,
            1,
            &sp("unresolved.drv"),
            BuildStatus::Resolved,
            Some(&sp("resolved.drv")),
        )
        .await;
        // A successful buildstep for the resolved drv (could be any build)
        insert_step(&mut conn, 2, 1, &sp("resolved.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("result")).await;

        // Looking up via the unresolved drv path should find the output
        // through the resolvedDrvPath chain.
        let results = conn
            .resolve_drv_output_chains(&test_store_dir(), &[(&sp("unresolved.drv"), &[&on("out")])])
            .await
            .unwrap();
        assert_eq!(results, vec![Some(sp("result"))]);
    }

    /// A depth-2 chain where the first step was resolved:
    /// unresolved.drv (status=13, resolvedDrvPath→resolved.drv) →
    /// resolved.drv outputs a .drv path → that .drv has the final output.
    #[tokio::test]
    async fn resolve_depth_2_through_resolved_step() {
        let (_pg, mut conn) = setup().await;

        // Build 1: unresolved step, resolved to resolved.drv
        insert_step_with_status(
            &mut conn,
            1,
            1,
            &sp("unresolved.drv"),
            BuildStatus::Resolved,
            Some(&sp("resolved.drv")),
        )
        .await;
        insert_step(&mut conn, 2, 1, &sp("resolved.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("intermediate.drv")).await;

        // Build 3: the intermediate drv
        insert_step(&mut conn, 3, 1, &sp("intermediate.drv")).await;
        insert_output(&mut conn, 3, 1, "out", &sp("final")).await;

        let results = conn
            .resolve_drv_output_chains(
                &test_store_dir(),
                &[(&sp("unresolved.drv"), &[&on("out"), &on("out")])],
            )
            .await
            .unwrap();
        assert_eq!(results, vec![Some(sp("final"))]);
    }

    /// Batch with ragged depths: one depth-1 (Opaque), one depth-2 (Built),
    /// one depth-3 (Built(Built(...))).
    #[tokio::test]
    async fn resolve_ragged_batch() {
        let (_pg, mut conn) = setup().await;

        // Depth 1: aaa.drv ^out => result-a
        insert_step(&mut conn, 1, 1, &sp("aaa.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("result-a")).await;

        // Depth 2: bbb.drv ^out => ccc.drv, ccc.drv ^lib => result-b
        insert_step(&mut conn, 2, 1, &sp("bbb.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("ccc.drv")).await;
        insert_step(&mut conn, 3, 1, &sp("ccc.drv")).await;
        insert_output(&mut conn, 3, 1, "lib", &sp("result-b")).await;

        // Depth 3: ddd.drv ^out => eee.drv, eee.drv ^dev => fff.drv, fff.drv ^bin => result-c
        insert_step(&mut conn, 4, 1, &sp("ddd.drv")).await;
        insert_output(&mut conn, 4, 1, "out", &sp("eee.drv")).await;
        insert_step(&mut conn, 5, 1, &sp("eee.drv")).await;
        insert_output(&mut conn, 5, 1, "dev", &sp("fff.drv")).await;
        insert_step(&mut conn, 6, 1, &sp("fff.drv")).await;
        insert_output(&mut conn, 6, 1, "bin", &sp("result-c")).await;

        let results = conn
            .resolve_drv_output_chains(
                &test_store_dir(),
                &[
                    (&sp("aaa.drv"), &[&on("out")]),
                    (&sp("bbb.drv"), &[&on("out"), &on("lib")]),
                    (&sp("ddd.drv"), &[&on("out"), &on("dev"), &on("bin")]),
                ],
            )
            .await
            .unwrap();
        assert_eq!(
            results,
            vec![
                Some(sp("result-a")),
                Some(sp("result-b")),
                Some(sp("result-c")),
            ]
        );
    }

    // -- resolve_drv_output (depth-1) tests ------------------------------------

    #[tokio::test]
    async fn resolve_drv_output_basic() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("result")).await;

        let result = conn
            .resolve_drv_output(&test_store_dir(), &sp("foo.drv"), &on("out"))
            .await
            .unwrap();
        assert_eq!(result, Some(sp("result")));
    }

    #[tokio::test]
    async fn resolve_drv_output_missing() {
        let (_pg, mut conn) = setup().await;
        let result = conn
            .resolve_drv_output(&test_store_dir(), &sp("nonexistent.drv"), &on("out"))
            .await
            .unwrap();
        assert_eq!(result, None);
    }

    #[tokio::test]
    async fn resolve_drv_output_picks_latest_build() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("old-result")).await;
        insert_step(&mut conn, 5, 1, &sp("foo.drv")).await;
        insert_output(&mut conn, 5, 1, "out", &sp("new-result")).await;

        let result = conn
            .resolve_drv_output(&test_store_dir(), &sp("foo.drv"), &on("out"))
            .await
            .unwrap();
        assert_eq!(result, Some(sp("new-result")));
    }

    /// Depth-1 lookup where the only buildstep for the drv has
    /// status=Resolved(13) with `resolvedDrvPath` pointing to
    /// a different drv whose successful buildstep has the outputs.
    /// This matches the production scenario: ca-depending-on-ca.drv
    /// was resolved to a different drv, and ca-depending-on-ca-
    /// depending-on-ca needs to look up its output.
    #[tokio::test]
    async fn resolve_depth_1_via_resolved_step() {
        let (_pg, mut conn) = setup().await;

        // Build 1, step 1: unresolved ca-depending-on-ca.drv
        //   status=13 (Resolved), resolvedDrvPath points to the resolved drv
        insert_step_with_status(
            &mut conn,
            1,
            1,
            &sp("unresolved-ca-dep.drv"),
            BuildStatus::Resolved,
            Some(&sp("resolved-ca-dep.drv")),
        )
        .await;
        // Build 2: the resolved drv was built successfully
        insert_step(&mut conn, 2, 1, &sp("resolved-ca-dep.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("ca-dep-output")).await;

        // Depth-1 chain: look up "out" of the unresolved drv path.
        // The query should follow resolvedDrvPath to find the output.
        let results = conn
            .resolve_drv_output_chains(
                &test_store_dir(),
                &[(&sp("unresolved-ca-dep.drv"), &[&on("out")])],
            )
            .await
            .unwrap();
        assert_eq!(results, vec![Some(sp("ca-dep-output"))]);
    }
}

use std::collections::BTreeMap;

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use super::{Connection, Handle, Transaction, names_and_paths};
use crate::models::{Build, BuildID, BuildSmall, BuildStatus, UpdateBuild};

impl<C: std::ops::DerefMut<Target = sqlx::PgConnection>> Handle<C> {
    #[tracing::instrument(skip(self), err)]
    pub async fn get_not_finished_builds_fast(&mut self) -> crate::Result<Vec<BuildSmall>> {
        Ok(sqlx::query_as!(
            BuildSmall,
            r#"
            SELECT
              id,
              globalPriority
            FROM builds
            WHERE finished = 0;"#
        )
        .fetch_all(&mut *self.conn)
        .await?)
    }

    #[tracing::instrument(skip(self, store_dir), err)]
    pub async fn get_not_finished_builds(
        &mut self,
        store_dir: &StoreDir,
    ) -> crate::Result<Vec<Build>> {
        let rows = sqlx::query_as!(
            Build::<String>,
            r#"
            SELECT
              builds.id,
              builds.jobset_id,
              jobsets.project as project,
              jobsets.name as jobset,
              job,
              drvPath,
              maxsilent,
              timeout,
              timestamp,
              globalPriority,
              priority
            FROM builds
            INNER JOIN jobsets ON builds.jobset_id = jobsets.id
            WHERE finished = 0 ORDER BY globalPriority desc, schedulingshares, random();"#
        )
        .fetch_all(&mut *self.conn)
        .await?;
        rows.into_iter()
            .map(|r| Ok(r.parse_paths(store_dir)?))
            .collect()
    }

    pub async fn insert_debug_build(
        &mut self,
        store_dir: &StoreDir,
        jobset_id: i32,
        drv_path: &StorePath,
        system: &str,
    ) -> crate::Result<()> {
        let drv_path = store_dir.display(drv_path).to_string();
        sqlx::query!(
            r#"INSERT INTO builds (
              finished,
              timestamp,
              jobset_id,
              job,
              nixname,
              drvpath,
              system,
              maxsilent,
              timeout,
              ischannel,
              iscurrent,
              priority,
              globalpriority,
              keep
            ) VALUES (
              0,
              EXTRACT(EPOCH FROM NOW())::INT8,
              $1,
              'debug',
              'debug',
              $2,
              $3,
              7200,
              36000,
              0,
              0,
              100,
              0,
            0);"#,
            jobset_id,
            drv_path,
            system,
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    pub async fn get_build_output_for_path(
        &mut self,
        store_dir: &StoreDir,
        out_path: &StorePath,
    ) -> crate::Result<Option<crate::models::BuildOutput>> {
        let out_path = store_dir.display(out_path).to_string();
        Ok(sqlx::query_as!(
            crate::models::BuildOutput,
            r#"
            SELECT
              id, buildStatus AS "buildstatus!: BuildStatus", releaseName, closureSize, size
            FROM builds b
            JOIN buildoutputs o on b.id = o.build
            WHERE finished = 1 and (buildStatus = 0 or buildStatus = 6) and path = $1
            LIMIT 1;"#,
            out_path.as_str(),
        )
        .fetch_optional(&mut *self.conn)
        .await?)
    }

    pub async fn get_build_products_for_build_id(
        &mut self,
        build_id: BuildID,
        store_dir: &StoreDir,
    ) -> crate::Result<Vec<nix_support::BuildProduct>> {
        let rows = sqlx::query_as!(
            crate::models::BuildProductRow,
            r#"
            SELECT
              build,
              productnr,
              type,
              subtype,
              fileSize,
              sha256hash,
              path,
              name,
              defaultPath
            FROM buildproducts
            WHERE build = $1 ORDER BY productnr;"#,
            build_id
        )
        .fetch_all(&mut *self.conn)
        .await?;
        rows.into_iter()
            .map(|r| Ok(r.into_build_product(store_dir)?))
            .collect()
    }

    pub async fn get_build_metrics_for_build_id(
        &mut self,
        build_id: BuildID,
    ) -> crate::Result<Vec<(nix_support::BuildMetricName, nix_support::BuildMetric)>> {
        let rows = sqlx::query!(
            r#"
            SELECT
              name, unit, value
            FROM buildmetrics
            WHERE build = $1;"#,
            build_id
        )
        .fetch_all(&mut *self.conn)
        .await?;
        Ok(rows
            .into_iter()
            .map(|r| {
                let metric = nix_support::BuildMetric {
                    unit: r.unit,
                    value: r.value,
                };
                (r.name, metric)
            })
            .collect())
    }

    #[tracing::instrument(skip(self, status, start_time, stop_time, is_cached_build), err)]
    pub async fn update_build_after_failure(
        &mut self,
        build_id: BuildID,
        status: BuildStatus,
        start_time: crate::Timestamp,
        stop_time: crate::Timestamp,
        is_cached_build: bool,
    ) -> crate::Result<()> {
        sqlx::query!(
            r#"
            UPDATE builds SET
              finished = 1,
              buildStatus = $2,
              startTime = $3,
              stopTime = $4,
              isCachedBuild = $5,
              notificationPendingSince = $4
            WHERE
              id = $1 AND finished = 0"#,
            build_id,
            status as i32,
            start_time,
            stop_time,
            i32::from(is_cached_build),
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, status), err)]
    pub async fn update_build_after_previous_failure(
        &mut self,
        build_id: BuildID,
        status: BuildStatus,
    ) -> crate::Result<()> {
        let now = jiff::Timestamp::now().as_second();
        self.update_build_after_failure(build_id, status, now, now, true)
            .await
    }

    #[tracing::instrument(skip(self, store_dir), err)]
    pub async fn get_drv_path_from_build(
        &mut self,
        store_dir: &StoreDir,
        build_id: BuildID,
    ) -> crate::Result<Option<StorePath>> {
        Ok(
            sqlx::query!("SELECT drvPath FROM Builds WHERE id = $1", build_id)
                .fetch_optional(&mut *self.conn)
                .await?
                .map(|v| store_dir.parse(&v.drvpath))
                .transpose()?,
        )
    }
}

impl Connection {
    /// Mark a build aborted and tell `build_finished` listeners, in one
    /// transaction: whoever is waiting on the row (hydra-ad-hoc, say)
    /// cares that it is finished, not why.
    #[tracing::instrument(skip(self), err)]
    pub async fn abort_build(&mut self, build_id: BuildID) -> crate::Result<()> {
        let mut tx = self.begin_transaction().await?;
        sqlx::query!(
            "UPDATE builds SET finished = 1, buildStatus = $2, startTime = $3, stopTime = $3 where id = $1 and finished = 0",
            build_id,
            BuildStatus::Aborted as i32,
            jiff::Timestamp::now().as_second(),
        )
        .execute(&mut *tx.conn)
        .await?;
        tx.notify_build_finished(build_id, &[]).await?;
        tx.commit().await?;
        Ok(())
    }
}

impl Transaction<'_> {
    /// Mark an unfinished build finished. Returns false if it already was.
    #[tracing::instrument(skip(self, v), err)]
    async fn update_build(&mut self, build_id: BuildID, v: UpdateBuild<'_>) -> crate::Result<bool> {
        let result = sqlx::query!(
            r#"
            UPDATE builds SET
              finished = 1,
              buildStatus = $2,
              startTime = $3,
              stopTime = $4,
              size = $5,
              closureSize = $6,
              releaseName = $7,
              isCachedBuild = $8,
              notificationPendingSince = $4
            WHERE
              id = $1 AND finished = 0"#,
            build_id,
            v.status as i32,
            v.start_time,
            v.stop_time,
            v.size,
            v.closure_size,
            v.release_name,
            i32::from(v.is_cached_build),
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(result.rows_affected() > 0)
    }

    #[tracing::instrument(skip(self, store_dir, outputs), err)]
    async fn upsert_build_outputs(
        &mut self,
        store_dir: &StoreDir,
        build_id: BuildID,
        outputs: &BTreeMap<OutputName, StorePath>,
    ) -> crate::Result<()> {
        let (names, paths) = names_and_paths(store_dir, outputs);
        // The evaluator pre-inserts a build's BuildOutputs rows and this
        // used to only update them; a build filed without an evaluation
        // (hydra-ad-hoc) has none, and hydra-update-gc-roots reads this
        // table, so insert or update.
        sqlx::query!(
            "INSERT INTO buildoutputs (build, name, path)
             SELECT $1, name, path FROM UNNEST($2::text[], $3::text[]) AS o(name, path)
             ON CONFLICT (build, name) DO UPDATE SET path = EXCLUDED.path",
            build_id,
            &names,
            &paths,
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip_all, fields(build_id), err)]
    async fn replace_build_products(
        &mut self,
        store_dir: &StoreDir,
        build_id: BuildID,
        products: &[nix_support::BuildProduct],
    ) -> crate::Result<()> {
        sqlx::query!("DELETE FROM buildproducts WHERE build = $1", build_id)
            .execute(&mut *self.conn)
            .await?;
        if products.is_empty() {
            return Ok(());
        }
        let column = |f: fn(&nix_support::BuildProduct) -> String| -> Vec<String> {
            products.iter().map(f).collect()
        };
        let file_sizes: Vec<Option<i64>> = products
            .iter()
            .map(|p| p.file_size.and_then(|s| i64::try_from(s).ok()))
            .collect();
        let hashes: Vec<Option<String>> = products
            .iter()
            .map(|p| p.sha256hash.as_ref().map(|h| format!("{h:x}")))
            .collect();
        // sqlx expects array parameters to have non-null elements, so `as _`
        // skips its type check for the arrays that hold NULLs.
        sqlx::query!(
            r#"
            INSERT INTO buildproducts
              (build, productnr, type, subtype, fileSize, sha256hash, path, name, defaultPath)
            SELECT $1, nr::int, type, subtype, fileSize, sha256hash, path, name, defaultPath
            FROM UNNEST($2::text[], $3::text[], $4::int8[], $5::text[], $6::text[], $7::text[], $8::text[])
              WITH ORDINALITY AS p(type, subtype, fileSize, sha256hash, path, name, defaultPath, nr)
            "#,
            build_id,
            &column(|p| p.r#type.clone()),
            &column(|p| p.subtype.clone()),
            &file_sizes as _,
            &hashes as _,
            &products
                .iter()
                .map(|p| p.path.print(store_dir))
                .collect::<Vec<_>>(),
            &column(|p| p.name.clone()),
            &column(|p| p.default_path.clone()),
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip_all, fields(build_id = build.id), err)]
    async fn replace_build_metrics(
        &mut self,
        build: &crate::models::MarkBuildSuccessData<'_>,
    ) -> crate::Result<()> {
        sqlx::query!("DELETE FROM buildmetrics WHERE build = $1", build.id)
            .execute(&mut *self.conn)
            .await?;
        if build.metrics.is_empty() {
            return Ok(());
        }
        let names: Vec<&str> = build.metrics.keys().map(String::as_str).collect();
        let units: Vec<Option<&str>> = build.metrics.values().map(|m| m.unit.as_deref()).collect();
        let values: Vec<f64> = build.metrics.values().map(|m| m.value).collect();
        // `query!` types `text[]` parameters as `&[String]`. `as _` turns that
        // check off for `names`, which holds `&str`, and `units`, which holds NULLs.
        sqlx::query!(
            r#"
            INSERT INTO buildmetrics (build, name, unit, value, project, jobset, job, timestamp)
            SELECT $1, name, unit, value, $5, $6, $7, $8
            FROM UNNEST($2::text[], $3::text[], $4::float8[]) AS m(name, unit, value)
            "#,
            build.id,
            &names as _,
            &units as _,
            &values,
            build.project_name,
            build.jobset_name,
            build.name,
            build.timestamp,
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(
        skip(self, build, is_cached_build, start_time, stop_time, store_dir),
        err
    )]
    pub async fn mark_succeeded_build(
        &mut self,
        build: crate::models::MarkBuildSuccessData<'_>,
        is_cached_build: bool,
        start_time: crate::Timestamp,
        stop_time: crate::Timestamp,
        store_dir: &StoreDir,
    ) -> crate::Result<()> {
        if build.finished_in_db {
            return Ok(());
        }

        let updated = self
            .update_build(
                build.id,
                UpdateBuild {
                    status: if build.failed {
                        BuildStatus::FailedWithOutput
                    } else {
                        BuildStatus::Success
                    },
                    start_time,
                    stop_time,
                    size: i64::try_from(build.size)?,
                    closure_size: i64::try_from(build.closure_size)?,
                    release_name: build.release_name,
                    is_cached_build,
                },
            )
            .await?;
        if !updated {
            return Ok(());
        }

        self.upsert_build_outputs(store_dir, build.id, build.outputs)
            .await?;
        self.replace_build_products(store_dir, build.id, build.products)
            .await?;
        self.replace_build_metrics(&build).await
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::connection::test_helpers::{on, setup, sp, test_store_dir};
    use crate::models::MarkBuildSuccessData;

    /// The product and metric inserts bind their arrays with `as _`, which
    /// turns off sqlx's compile-time type check. Read the rows back instead.
    #[tokio::test]
    async fn mark_succeeded_build_writes_products_and_metrics_once() {
        let (_pg, mut conn) = setup().await;
        let sd = test_store_dir();
        sqlx::query!(
            "INSERT INTO builds (id, finished, timestamp, jobset_id, job, drvPath, system)
             VALUES (1, 0, 0, 1, 'job', 'job.drv', 'x86_64-linux')"
        )
        .execute(&mut *conn.conn)
        .await
        .unwrap();

        let product = |name: &str, sha256hash, file_size| nix_support::BuildProduct {
            path: (sp("out"), name.into()).into(),
            default_path: String::new(),
            r#type: "file".into(),
            subtype: "doc".into(),
            name: name.into(),
            is_regular: true,
            sha256hash,
            file_size,
        };
        let products = [
            product(
                "a",
                Some(harmonia_utils_hash::Sha256::from_slice(&[0xab; 32]).unwrap()),
                Some(42),
            ),
            product("b", None, None),
        ];
        let metric = |unit: Option<&str>, value| nix_support::BuildMetric {
            unit: unit.map(Into::into),
            value,
        };
        let metrics = BTreeMap::from([
            ("count".to_owned(), metric(None, 3.0)),
            ("time".to_owned(), metric(Some("s"), 1.5)),
        ]);
        let outputs = BTreeMap::from([(on("out"), sp("out"))]);
        let data = |products| MarkBuildSuccessData {
            id: 1,
            name: "job",
            project_name: "project",
            jobset_name: "jobset",
            finished_in_db: false,
            timestamp: 0,
            failed: false,
            closure_size: 0,
            size: 0,
            release_name: None,
            outputs: &outputs,
            products,
            metrics: &metrics,
        };

        let mut tx = conn.begin_transaction().await.unwrap();
        tx.mark_succeeded_build(data(&products), false, 1, 2, &sd)
            .await
            .unwrap();
        // The build is finished now, so this call changes nothing.
        tx.mark_succeeded_build(data(&[]), false, 1, 2, &sd)
            .await
            .unwrap();
        tx.commit().await.unwrap();

        let rows = sqlx::query!(
            "SELECT productnr, path, filesize, sha256hash FROM buildproducts WHERE build = 1 ORDER BY productnr"
        )
        .fetch_all(&mut *conn.conn)
        .await
        .unwrap();
        let rows: Vec<_> = rows
            .into_iter()
            .map(|r| (r.productnr, r.path, r.filesize, r.sha256hash))
            .collect();
        let out = sd.display(&sp("out")).to_string();
        assert_eq!(
            rows,
            [
                (1, Some(format!("{out}/a")), Some(42), Some("ab".repeat(32))),
                (2, Some(format!("{out}/b")), None, None),
            ]
        );

        let rows = sqlx::query!(
            "SELECT name, unit, value FROM buildmetrics WHERE build = 1 ORDER BY name"
        )
        .fetch_all(&mut *conn.conn)
        .await
        .unwrap();
        let rows: Vec<_> = rows
            .into_iter()
            .map(|r| (r.name, r.unit, r.value))
            .collect();
        assert_eq!(
            rows,
            [
                ("count".to_owned(), None, 3.0),
                ("time".to_owned(), Some("s".to_owned()), 1.5),
            ]
        );
    }
}

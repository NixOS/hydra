use std::collections::BTreeMap;
use std::fmt::Write as _;

use sqlx::Acquire;

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use super::models::{
    Build, BuildSmall, BuildStatus, BuildSteps, InsertBuildMetric, InsertBuildProduct,
    InsertBuildStep, InsertBuildStepOutput, Jobset, UpdateBuild, UpdateBuildStep,
    UpdateBuildStepInFinish,
};

#[derive(Debug)]
pub struct Connection {
    conn: sqlx::pool::PoolConnection<sqlx::Postgres>,
}

#[derive(Debug)]
pub struct Transaction<'a> {
    tx: sqlx::PgTransaction<'a>,
}

impl Connection {
    #[must_use]
    pub const fn new(conn: sqlx::pool::PoolConnection<sqlx::Postgres>) -> Self {
        Self { conn }
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn begin_transaction(&mut self) -> crate::Result<Transaction<'_>> {
        let tx = self.conn.begin().await?;
        Ok(Transaction { tx })
    }

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

    #[tracing::instrument(skip(self), err)]
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

    #[tracing::instrument(skip(self), err)]
    pub async fn get_jobsets(&mut self) -> crate::Result<Vec<Jobset>> {
        Ok(sqlx::query_as!(
            Jobset,
            r#"
            SELECT
              project,
              name,
              schedulingshares
            FROM jobsets"#
        )
        .fetch_all(&mut *self.conn)
        .await?)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_jobset_scheduling_shares(
        &mut self,
        jobset_id: i32,
    ) -> crate::Result<Option<u32>> {
        Ok(sqlx::query!(
            "SELECT schedulingshares FROM jobsets WHERE id = $1",
            jobset_id,
        )
        .fetch_optional(&mut *self.conn)
        .await?
        .map(|v| u32::try_from(v.schedulingshares))
        .transpose()?)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_jobset_build_steps(
        &mut self,
        jobset_id: i32,
        scheduling_window: i64,
    ) -> crate::Result<Vec<BuildSteps>> {
        Ok(sqlx::query_as!(
            BuildSteps,
            r#"
            SELECT s.startTime, s.stopTime FROM buildsteps s join builds b on build = id
            WHERE
              s.startTime IS NOT NULL AND
              s.stopTime > (EXTRACT(epoch FROM NOW())::bigint - $1) AND
              jobset_id = $2
            "#,
            scheduling_window,
            jobset_id,
        )
        .fetch_all(&mut *self.conn)
        .await?)
    }

    // TODO Currently unused. In the old C++ queue-runner, this was called
    // in queue-monitor.cc to mark GC'ed builds as aborted. The Rust
    // queue runner apparently doesn't handle that case yet.
    #[tracing::instrument(skip(self), err)]
    pub async fn abort_build(&mut self, build_id: i32) -> crate::Result<()> {
        #[allow(clippy::cast_possible_truncation)]
        sqlx::query!(
            "UPDATE builds SET finished = 1, buildStatus = $2, startTime = $3, stopTime = $3 where id = $1 and finished = 0",
            build_id,
            BuildStatus::Aborted as i32,
            // TODO migrate to 64bit timestamp
            jiff::Timestamp::now().as_second() as i32,
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, paths), err)]
    pub async fn check_if_paths_failed(
        &mut self,
        store_dir: &StoreDir,
        paths: &[StorePath],
    ) -> crate::Result<bool> {
        let paths: Vec<String> = paths
            .iter()
            .map(|p| store_dir.display(p).to_string())
            .collect();
        Ok(
            !sqlx::query!("SELECT path FROM failedpaths where path = ANY($1)", &paths)
                .fetch_all(&mut *self.conn)
                .await?
                .is_empty(),
        )
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn clear_busy(&mut self, stop_time: i32) -> crate::Result<()> {
        sqlx::query!(
            "UPDATE buildsteps SET busy = 0, status = $1, stopTime = $2 WHERE busy != 0;",
            BuildStatus::Aborted as i32,
            Some(stop_time),
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    /// Finalize a single still-busy buildstep with the given status. Used to
    /// reconcile a specific orphaned step in the DB without touching any other
    /// step.
    pub async fn clear_busy_step(
        &mut self,
        build_id: crate::models::BuildID,
        step_nr: i32,
        stop_time: i32,
        status: BuildStatus,
    ) -> crate::Result<()> {
        sqlx::query!(
            "UPDATE buildsteps SET busy = 0, status = $1, stopTime = $2 \
             WHERE build = $3 AND stepnr = $4 AND busy != 0;",
            status as i32,
            Some(stop_time),
            build_id,
            step_nr,
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, step), err)]
    pub async fn update_build_step(&mut self, step: UpdateBuildStep) -> crate::Result<()> {
        sqlx::query!(
            "UPDATE buildsteps SET busy = $1 WHERE build = $2 AND stepnr = $3 AND busy != 0 AND status IS NULL",
            step.status as i32,
            step.build_id,
            step.step_nr,
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
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
              EXTRACT(EPOCH FROM NOW())::INT4,
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
    ) -> crate::Result<Option<super::models::BuildOutput>> {
        let out_path = store_dir.display(out_path).to_string();
        Ok(sqlx::query_as!(
            super::models::BuildOutput,
            r#"
            SELECT
              id, buildStatus, releaseName, closureSize, size
            FROM builds b
            JOIN buildoutputs o on b.id = o.build
            WHERE finished = 1 and (buildStatus = 0 or buildStatus = 6) and path = $1;"#,
            out_path.as_str(),
        )
        .fetch_optional(&mut *self.conn)
        .await?)
    }

    pub async fn get_build_products_for_build_id(
        &mut self,
        build_id: i32,
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
        build_id: i32,
    ) -> crate::Result<Vec<(nix_support::BuildMetricName, nix_support::BuildMetric)>> {
        let rows = sqlx::query_as!(
            crate::models::OwnedBuildMetric,
            r#"
            SELECT
              name, unit, value
            FROM buildmetrics
            WHERE build = $1;"#,
            build_id
        )
        .fetch_all(&mut *self.conn)
        .await?;
        Ok(rows.into_iter().map(Into::into).collect())
    }

    /// Resolve output paths for derivation chains via `buildstepoutputs`.
    ///
    /// Each entry is `(root_drv_path, &[output_name, ...])` representing a
    /// chain like `root.drv^out1^out2`. The recursive CTE walks the chain:
    /// look up `root.drv`'s `out1` output to get an intermediate drv path,
    /// then look up that drv's `out2`, etc. Returns the final resolved path
    /// for each chain (or `None` if any step fails).
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
                        "root": store_dir.display(*root).to_string(),
                        "chain": outputs.iter().map(AsRef::as_ref).collect::<Vec<&str>>(),
                    })
                })
                .collect(),
        );

        let rows = sqlx::query_as::<_, (i32, Option<String>)>(
            "
            WITH RECURSIVE input AS (
                SELECT (ordinality)::int AS idx,
                       elem->>'root' AS drv,
                       ARRAY(SELECT jsonb_array_elements_text(elem->'chain')) AS chain
                FROM jsonb_array_elements($1::jsonb)
                    WITH ORDINALITY AS t(elem, ordinality)
            ),
            resolve(idx, drv_path, step) AS (
                SELECT idx, drv, 1 FROM input

                UNION ALL

                SELECT r.idx, sub.path, r.step + 1
                FROM resolve r
                JOIN input i ON i.idx = r.idx
                CROSS JOIN LATERAL (
                    SELECT o.path
                    FROM buildsteps s
                    JOIN buildstepoutputs o
                        ON s.build = o.build AND s.stepnr = o.stepnr
                    WHERE s.drvPath = r.drv_path
                      AND o.name = i.chain[r.step]
                      AND o.path IS NOT NULL
                      AND s.status = 0
                    ORDER BY s.build DESC
                    LIMIT 1
                ) sub
                WHERE r.step <= array_length(i.chain, 1)
                  AND r.drv_path IS NOT NULL
            )
            SELECT i.idx, r.drv_path
            FROM input i
            LEFT JOIN resolve r
                ON r.idx = i.idx
                AND r.step = array_length(i.chain, 1) + 1
            ORDER BY i.idx
            ",
        )
        .bind(&json_input)
        .fetch_all(&mut *self.conn)
        .await?;

        let mut results = vec![None; chains.len()];
        for (idx, path) in rows {
            let i = usize::try_from(idx - 1)?;
            results[i] = path.map(|p| store_dir.parse(&p)).transpose()?;
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
        let drv_display = store_dir.display(drv_path).to_string();
        let output_name_str: &str = output_name.as_ref();
        let row: Option<(String,)> = sqlx::query_as(
            r"SELECT o.path
              FROM buildsteps s
              JOIN buildstepoutputs o
                  ON s.build = o.build AND s.stepnr = o.stepnr
              WHERE s.drvPath = $1
                AND o.name = $2
                AND o.path IS NOT NULL
                AND s.status = 0
              ORDER BY s.build DESC
              LIMIT 1",
        )
        .bind(&drv_display)
        .bind(output_name_str)
        .fetch_optional(&mut *self.conn)
        .await?;

        row.map(|(path,)| Ok(store_dir.parse(&path)?)).transpose()
    }
}

impl Transaction<'_> {
    #[tracing::instrument(skip(self), err)]
    pub async fn commit(self) -> crate::Result<()> {
        Ok(self.tx.commit().await?)
    }

    #[tracing::instrument(skip(self, v), err)]
    pub async fn update_build(&mut self, build_id: i32, v: UpdateBuild<'_>) -> crate::Result<()> {
        sqlx::query!(
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
              id = $1"#,
            build_id,
            v.status as i32,
            v.start_time,
            v.stop_time,
            v.size,
            v.closure_size,
            v.release_name,
            i32::from(v.is_cached_build),
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, status, start_time, stop_time, is_cached_build), err)]
    pub async fn update_build_after_failure(
        &mut self,
        build_id: i32,
        status: BuildStatus,
        start_time: i32,
        stop_time: i32,
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
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, status), err)]
    pub async fn update_build_after_previous_failure(
        &mut self,
        build_id: i32,
        status: BuildStatus,
    ) -> crate::Result<()> {
        #[allow(clippy::cast_possible_truncation)]
        sqlx::query!(
            r#"
            UPDATE builds SET
              finished = 1,
              buildStatus = $2,
              startTime = $3,
              stopTime = $3,
              isCachedBuild = 1,
              notificationPendingSince = $3
            WHERE
              id = $1 AND finished = 0"#,
            build_id,
            status as i32,
            // TODO migrate to 64bit timestamp
            jiff::Timestamp::now().as_second() as i32,
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, name, path), err)]
    pub async fn update_build_output(
        &mut self,
        store_dir: &StoreDir,
        build_id: i32,
        name: &str,
        path: &StorePath,
    ) -> crate::Result<()> {
        let path = store_dir.display(path).to_string();
        // TODO: support inserting multiple at the same time
        sqlx::query!(
            "UPDATE buildoutputs SET path = $3 WHERE build = $1 AND name = $2",
            build_id,
            name,
            path.as_str(),
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_last_build_step_id(
        &mut self,
        store_dir: &StoreDir,
        path: &StorePath,
    ) -> crate::Result<Option<i32>> {
        let path = store_dir.display(path).to_string();
        Ok(sqlx::query!("SELECT MAX(build) FROM buildsteps WHERE drvPath = $1 and startTime != 0 and stopTime != 0 and status = 1", path.as_str())
            .fetch_optional(&mut *self.tx)
            .await?
            .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_last_build_step_id_for_output_path(
        &mut self,
        store_dir: &StoreDir,
        path: &StorePath,
    ) -> crate::Result<Option<i32>> {
        let path = store_dir.display(path).to_string();
        Ok(sqlx::query!(
            r#"
                  SELECT MAX(s.build) FROM buildsteps s
                  JOIN BuildStepOutputs o ON s.build = o.build
                  WHERE startTime != 0
                    AND stopTime != 0
                    AND status = 1
                    AND path = $1
                "#,
            path.as_str(),
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self, drv_path, name), err)]
    pub async fn get_last_build_step_id_for_output_with_drv(
        &mut self,
        store_dir: &StoreDir,
        drv_path: &StorePath,
        name: &str,
    ) -> crate::Result<Option<i32>> {
        let drv_path = store_dir.display(drv_path).to_string();
        Ok(sqlx::query!(
            r#"
                  SELECT MAX(s.build) FROM buildsteps s
                  JOIN BuildStepOutputs o ON s.build = o.build
                  WHERE startTime != 0
                    AND stopTime != 0
                    AND status = 1
                    AND drvPath = $1
                    AND name = $2
                "#,
            drv_path,
            name,
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self, step), err)]
    pub async fn insert_build_step(
        &mut self,
        store_dir: &StoreDir,
        step: InsertBuildStep<'_>,
    ) -> crate::Result<Option<i32>> {
        // stepnr is MAX(stepnr) + 1; concurrent transactions for the same
        // build pick the same number and all but one return None and retry.
        // The queue runner serializes the hot dispatch path with an
        // in-process per-build lock, so this only happens on rare paths.
        let drv_path = store_dir.display(step.drv_path).to_string();
        let success = sqlx::query!(
            r#"
              WITH max AS (SELECT MAX(stepnr) AS val FROM buildsteps WHERE build = $1),
                new_stepnr AS (SELECT
                    CASE
                        WHEN val IS NULL THEN 1
                        ELSE val + 1
                    END
                    AS val FROM max)
              INSERT INTO buildsteps (
                build,
                stepnr,
                type,
                drvPath,
                busy,
                startTime,
                stopTime,
                system,
                status,
                propagatedFrom,
                errorMsg,
                machine
              ) VALUES (
                $1, (SELECT val FROM new_stepnr), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
              )
              ON CONFLICT DO NOTHING
              RETURNING stepnr
            "#,
            step.build_id,
            step.r#type as i32,
            drv_path.as_str(),
            i32::from(step.busy),
            step.start_time,
            step.stop_time,
            step.platform,
            if step.status == BuildStatus::Busy {
                None
            } else {
                Some(step.status as i32)
            },
            step.propagated_from,
            step.error_msg,
            step.machine,
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .map(|v| v.stepnr);
        Ok(success)
    }

    #[tracing::instrument(skip(self, outputs), err)]
    pub async fn insert_build_step_outputs(
        &mut self,
        store_dir: &StoreDir,
        outputs: &[InsertBuildStepOutput],
    ) -> crate::Result<()> {
        if outputs.is_empty() {
            return Ok(());
        }

        let mut query_builder =
            sqlx::QueryBuilder::new("INSERT INTO buildstepoutputs (build, stepnr, name, path) ");

        query_builder.push_values(outputs, |mut b, output| {
            b.push_bind(output.build_id)
                .push_bind(output.step_nr)
                .push_bind(output.name.as_ref())
                .push_bind(
                    output
                        .path
                        .as_ref()
                        .map(|p| store_dir.display(p).to_string()),
                );
        });
        let query = query_builder.build();
        query.execute(&mut *self.tx).await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, name, path), err)]
    pub async fn update_build_step_output(
        &mut self,
        store_dir: &StoreDir,
        build_id: i32,
        step_nr: i32,
        name: &str,
        path: &StorePath,
    ) -> crate::Result<()> {
        let path = store_dir.display(path).to_string();
        // TODO: support inserting multiple at the same time
        sqlx::query!(
            "UPDATE buildstepoutputs SET path = $4 WHERE build = $1 AND stepnr = $2 AND name = $3",
            build_id,
            step_nr,
            name,
            path.as_str(),
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn find_build_step_outputs(
        &mut self,
        store_dir: &StoreDir,
        drv_path: &StorePath,
    ) -> crate::Result<BTreeMap<OutputName, StorePath>> {
        let drv_path = store_dir.display(drv_path).to_string();
        let items: Vec<(String, String)> = sqlx::query_as(
            r"SELECT o.name, o.path
              FROM buildstepoutputs o
              JOIN buildsteps s ON s.build = o.build AND s.stepnr = o.stepnr
              WHERE s.drvpath = $1 AND o.path IS NOT NULL",
        )
        .bind(drv_path)
        .fetch_all(&mut *self.tx)
        .await?;

        items
            .into_iter()
            .map(|(name, path)| -> crate::Result<_> {
                let name: OutputName = name.parse()?;
                let path: StorePath = store_dir.parse(&path)?;
                Ok((name, path))
            })
            .collect()
    }

    #[tracing::instrument(skip(self, res), err)]
    pub async fn update_build_step_in_finish(
        &mut self,
        res: UpdateBuildStepInFinish<'_>,
    ) -> crate::Result<()> {
        sqlx::query!(
            r#"
            UPDATE buildsteps SET
              busy = 0,
              status = $1,
              errorMsg = $4,
              startTime = $5,
              stopTime = $6,
              machine = $7,
              overhead = $8,
              timesBuilt = $9,
              isNonDeterministic = $10
            WHERE
              build = $2 AND stepnr = $3
            "#,
            res.status as i32,
            res.build_id,
            res.step_nr,
            res.error_msg,
            res.start_time,
            res.stop_time,
            res.machine,
            res.overhead,
            res.times_built,
            res.is_non_deterministic,
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id, step_nr), err)]
    pub async fn get_drv_path_from_build_step(
        &mut self,
        store_dir: &StoreDir,
        build_id: i32,
        step_nr: i32,
    ) -> crate::Result<Option<StorePath>> {
        sqlx::query!(
            "SELECT drvPath FROM BuildSteps WHERE build = $1 AND stepnr = $2",
            build_id,
            step_nr
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .and_then(|v| v.drvpath)
        .map(|p| store_dir.parse(&p))
        .transpose()
        .map_err(crate::Error::from)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_drv_path_from_build(
        &mut self,
        store_dir: &StoreDir,
        build_id: i32,
    ) -> crate::Result<Option<StorePath>> {
        sqlx::query!("SELECT drvPath FROM Builds WHERE id = $1", build_id)
            .fetch_optional(&mut *self.tx)
            .await?
            .map(|v| v.drvpath)
            .map(|p| store_dir.parse(&p))
            .transpose()
            .map_err(crate::Error::from)
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn check_if_build_is_not_finished(&mut self, build_id: i32) -> crate::Result<bool> {
        Ok(sqlx::query!(
            "SELECT id FROM builds WHERE id = $1 AND finished = 0",
            build_id,
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .is_some())
    }

    #[tracing::instrument(skip(self, p), err)]
    pub(crate) async fn insert_build_product(
        &mut self,
        p: InsertBuildProduct<'_>,
    ) -> crate::Result<()> {
        sqlx::query!(
            r#"
              INSERT INTO buildproducts (
                build,
                productnr,
                type,
                subtype,
                fileSize,
                sha256hash,
                path,
                name,
                defaultPath
              ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9
              )
            "#,
            p.build_id,
            p.product_nr,
            p.r#type,
            p.subtype,
            p.file_size,
            p.sha256hash.map(|h| {
                let bytes: &[u8] = h.as_ref();
                bytes.iter().fold(String::new(), |mut output, b| {
                    let _ = write!(output, "{b:02x}");
                    output
                })
            }) as Option<String>,
            p.path,
            p.name,
            p.default_path,
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn delete_build_products_by_build_id(&mut self, build_id: i32) -> crate::Result<()> {
        sqlx::query!("DELETE FROM buildproducts WHERE build = $1", build_id)
            .execute(&mut *self.tx)
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, metric), err)]
    pub(crate) async fn insert_build_metric(
        &mut self,
        metric: InsertBuildMetric<'_>,
    ) -> crate::Result<()> {
        sqlx::query!(
            r#"
              INSERT INTO buildmetrics (
                build,
                name,
                unit,
                value,
                project,
                jobset,
                job,
                timestamp
              ) VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8
              )
            "#,
            metric.build_id,
            metric.name,
            metric.unit,
            metric.value,
            metric.project,
            metric.jobset,
            metric.job,
            metric.timestamp,
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn delete_build_metrics_by_build_id(&mut self, build_id: i32) -> crate::Result<()> {
        sqlx::query!("DELETE FROM buildmetrics WHERE build = $1", build_id)
            .execute(&mut *self.tx)
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, path), err)]
    pub async fn insert_failed_paths(
        &mut self,
        store_dir: &StoreDir,
        path: &StorePath,
    ) -> crate::Result<()> {
        let path = store_dir.display(path).to_string();
        sqlx::query!(
            r#"
              INSERT INTO failedpaths (
                path
              ) VALUES (
                $1
              )
            "#,
            path.as_str(),
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    #[tracing::instrument(
        skip(
            self,
            start_time,
            build_id,
            platform,
            machine,
            status,
            error_msg,
            propagated_from
        ),
        err
    )]
    pub async fn create_build_step(
        &mut self,
        store_dir: &StoreDir,
        start_time: Option<i32>,
        build_id: crate::models::BuildID,
        drv_path: &StorePath,
        platform: Option<&str>,
        machine: String,
        status: BuildStatus,
        error_msg: Option<String>,
        propagated_from: Option<crate::models::BuildID>,
        outputs: BTreeMap<OutputName, Option<StorePath>>,
    ) -> crate::Result<i32> {
        let step_nr = loop {
            if let Some(step_nr) = self
                .insert_build_step(
                    store_dir,
                    InsertBuildStep {
                        build_id,
                        r#type: crate::models::BuildType::Build,
                        drv_path,
                        status,
                        busy: status == BuildStatus::Busy,
                        start_time,
                        stop_time: if status == BuildStatus::Busy {
                            None
                        } else {
                            start_time
                        },
                        platform,
                        propagated_from,
                        error_msg: error_msg.as_deref(),
                        machine: &machine,
                    },
                )
                .await?
            {
                break step_nr;
            }
        };

        self.insert_build_step_outputs(
            store_dir,
            &outputs
                .into_iter()
                .map(|(name, path)| InsertBuildStepOutput {
                    build_id,
                    step_nr,
                    name,
                    path,
                })
                .collect::<Vec<_>>(),
        )
        .await?;

        if status == BuildStatus::Busy {
            self.notify_step_started(build_id, step_nr).await?;
        }

        Ok(step_nr)
    }

    #[tracing::instrument(
        skip(self, start_time, stop_time, build_id, drv_path, outputs,),
        err,
        ret
    )]
    pub async fn create_local_step(
        &mut self,
        store_dir: &StoreDir,
        start_time: i32,
        stop_time: i32,
        build_id: crate::models::BuildID,
        drv_path: &StorePath,
        outputs: BTreeMap<OutputName, StorePath>,
    ) -> crate::Result<i32> {
        let step_nr = loop {
            if let Some(step_nr) = self
                .insert_build_step(
                    store_dir,
                    InsertBuildStep {
                        build_id,
                        r#type: crate::models::BuildType::Substitution,
                        drv_path,
                        status: BuildStatus::Success,
                        busy: false,
                        start_time: Some(start_time),
                        stop_time: Some(stop_time),
                        platform: None,
                        propagated_from: None,
                        error_msg: None,
                        machine: "",
                    },
                )
                .await?
            {
                break step_nr;
            }
        };

        let output_items: Vec<_> = outputs
            .into_iter()
            .map(|(name, path)| InsertBuildStepOutput {
                build_id,
                step_nr,
                name,
                path: Some(path),
            })
            .collect();

        self.insert_build_step_outputs(store_dir, &output_items)
            .await?;

        Ok(step_nr)
    }

    #[tracing::instrument(
        skip(self, start_time, stop_time, build_id, drv_path, output,),
        err,
        ret
    )]
    pub async fn create_substitution_step(
        &mut self,
        store_dir: &StoreDir,
        start_time: i32,
        stop_time: i32,
        build_id: crate::models::BuildID,
        drv_path: &StorePath,
        output: (OutputName, Option<StorePath>),
    ) -> crate::Result<i32> {
        let step_nr = loop {
            if let Some(step_nr) = self
                .insert_build_step(
                    store_dir,
                    InsertBuildStep {
                        build_id,
                        r#type: crate::models::BuildType::Substitution,
                        drv_path,
                        status: BuildStatus::Success,
                        busy: false,
                        start_time: Some(start_time),
                        stop_time: Some(stop_time),
                        platform: None,
                        propagated_from: None,
                        error_msg: None,
                        machine: "",
                    },
                )
                .await?
            {
                break step_nr;
            }
        };

        self.insert_build_step_outputs(
            store_dir,
            &[InsertBuildStepOutput {
                build_id,
                step_nr,
                name: output.0,
                path: output.1,
            }],
        )
        .await?;

        Ok(step_nr)
    }

    #[tracing::instrument(
        skip(self, build, is_cached_build, start_time, stop_time, store_dir),
        err
    )]
    pub async fn mark_succeeded_build(
        &mut self,
        build: crate::models::MarkBuildSuccessData<'_>,
        is_cached_build: bool,
        start_time: i32,
        stop_time: i32,
        store_dir: &StoreDir,
    ) -> crate::Result<()> {
        if build.finished_in_db {
            return Ok(());
        }

        if !self.check_if_build_is_not_finished(build.id).await? {
            return Ok(());
        }

        self.update_build(
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

        for (name, path) in &build.outputs {
            self.update_build_output(store_dir, build.id, name.as_ref(), path)
                .await?;
        }

        self.delete_build_products_by_build_id(build.id).await?;

        for (nr, p) in build.products.iter().enumerate() {
            let path_str = p.path.print(store_dir);
            self.insert_build_product(InsertBuildProduct {
                build_id: build.id,
                product_nr: i32::try_from(nr + 1)?,
                r#type: &p.r#type,
                subtype: &p.subtype,
                file_size: p.file_size.and_then(|s| i64::try_from(s).ok()),
                sha256hash: p.sha256hash.as_ref(),
                path: &path_str,
                name: &p.name,
                default_path: &p.default_path,
            })
            .await?;
        }

        self.delete_build_metrics_by_build_id(build.id).await?;
        for (name, m) in &build.metrics {
            self.insert_build_metric(InsertBuildMetric {
                build_id: build.id,
                name,
                unit: m.unit.as_deref(),
                value: m.value,
                project: build.project_name,
                jobset: build.jobset_name,
                job: build.name,
                timestamp: i32::try_from(build.timestamp)?, // TODO
            })
            .await?;
        }
        Ok(())
    }
}

impl Transaction<'_> {
    #[tracing::instrument(skip(self), err)]
    async fn notify_any(&mut self, channel: &str, msg: &str) -> crate::Result<()> {
        sqlx::query(
            r"SELECT pg_notify(chan, payload) from (values ($1, $2)) notifies(chan, payload)",
        )
        .bind(channel)
        .bind(msg)
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn notify_builds_added(&mut self) -> crate::Result<()> {
        self.notify_any("builds_added", "?").await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn notify_build_started(&mut self, build_id: i32) -> crate::Result<()> {
        self.notify_any("build_started", &build_id.to_string())
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id, dependent_ids,), err)]
    pub async fn notify_build_finished(
        &mut self,
        build_id: i32,
        dependent_ids: &[i32],
    ) -> crate::Result<()> {
        let mut q = vec![build_id.to_string()];
        q.extend(dependent_ids.iter().map(ToString::to_string));

        self.notify_any("build_finished", &q.join("\t")).await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id, step_nr,), err)]
    pub async fn notify_step_started(&mut self, build_id: i32, step_nr: i32) -> crate::Result<()> {
        self.notify_any("step_started", &format!("{build_id}\t{step_nr}"))
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id, step_nr, log_file,), err)]
    pub async fn notify_step_finished(
        &mut self,
        build_id: i32,
        step_nr: i32,
        log_file: &str,
    ) -> crate::Result<()> {
        self.notify_any(
            "step_finished",
            &format!("{build_id}\t{step_nr}\t{log_file}"),
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::RetryableError as _;

    fn test_store_dir() -> StoreDir {
        StoreDir::new("/nix/store").unwrap()
    }

    fn sp(s: &str) -> StorePath {
        format!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa0-{s}")
            .parse()
            .unwrap()
    }

    fn on(s: &str) -> OutputName {
        s.parse().unwrap()
    }

    async fn setup() -> (test_utils::TestPg, Connection) {
        let (pg, pool) = test_utils::TestPg::new().await;
        let mut conn = Connection::new(pool.acquire().await.unwrap());
        sqlx::raw_sql("SET session_replication_role = 'replica';")
            .execute(&mut *conn.conn)
            .await
            .unwrap();
        (pg, conn)
    }

    async fn insert_step(conn: &mut Connection, build: i32, stepnr: i32, drv_path: &StorePath) {
        let sd = test_store_dir();
        sqlx::query("INSERT INTO BuildSteps (build, stepnr, type, busy, drvPath, status) VALUES ($1, $2, 0, 0, $3, 0)")
            .bind(build)
            .bind(stepnr)
            .bind(sd.display(drv_path).to_string())
            .execute(&mut *conn.conn)
            .await
            .unwrap();
    }

    async fn insert_output(
        conn: &mut Connection,
        build: i32,
        stepnr: i32,
        name: &str,
        path: &StorePath,
    ) {
        sqlx::query(
            "INSERT INTO BuildStepOutputs (build, stepnr, name, path) VALUES ($1, $2, $3, $4)",
        )
        .bind(build)
        .bind(stepnr)
        .bind(name)
        .bind(test_store_dir().display(path).to_string())
        .execute(&mut *conn.conn)
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn clear_busy_step_finalizes_only_the_named_step() {
        async fn insert_busy(conn: &mut Connection, build: i32, stepnr: i32, drv: &StorePath) {
            sqlx::query("INSERT INTO BuildSteps (build, stepnr, type, busy, drvPath, status) VALUES ($1, $2, 0, 1, $3, NULL)")
                .bind(build)
                .bind(stepnr)
                .bind(test_store_dir().display(drv).to_string())
                .execute(&mut *conn.conn)
                .await
                .unwrap();
        }

        async fn busy_status(conn: &mut Connection, build: i32, stepnr: i32) -> (i32, Option<i32>) {
            sqlx::query_as::<_, (i32, Option<i32>)>(
                "SELECT busy, status FROM buildsteps WHERE build = $1 AND stepnr = $2",
            )
            .bind(build)
            .bind(stepnr)
            .fetch_one(&mut *conn.conn)
            .await
            .unwrap()
        }

        let (_pg, mut conn) = setup().await;
        // Two busy steps of one build (a duplicate-dispatch leaves an old
        // stepnr busy) plus a busy step of another build.
        insert_busy(&mut conn, 1, 1, &sp("foo.drv")).await;
        insert_busy(&mut conn, 1, 2, &sp("foo.drv")).await;
        insert_busy(&mut conn, 2, 1, &sp("bar.drv")).await;

        conn.clear_busy_step(1, 1, 12345, BuildStatus::Aborted)
            .await
            .unwrap();

        let (busy, status) = busy_status(&mut conn, 1, 1).await;
        assert_eq!(busy, 0, "named step must be cleared");
        assert_eq!(status, Some(BuildStatus::Aborted as i32));

        let (busy, _) = busy_status(&mut conn, 1, 2).await;
        assert_eq!(busy, 1, "sibling stepnr of same build must stay busy");

        let (busy, _) = busy_status(&mut conn, 2, 1).await;
        assert_eq!(busy, 1, "other build must stay busy");
    }

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

    // -- Simulate the Rust-side loop that replaces the recursive SQL ----------
    //
    // These mirror the resolved-step tests from the DB-column approach,
    // but use resolve_drv_output + an in-memory map instead of
    // resolvedDrvPath in the SQL.

    /// Helper: resolve a chain one level at a time using `resolve_drv_output`,
    /// translating through `resolved_map` between levels.
    async fn resolve_chain_with_map(
        conn: &mut Connection,
        resolved_map: &std::collections::HashMap<StorePath, StorePath>,
        root: &StorePath,
        outputs: &[&OutputName],
    ) -> Option<StorePath> {
        let sd = test_store_dir();
        let mut current = root.clone();
        for output_name in outputs {
            let translated = resolved_map.get(&current).cloned().unwrap_or(current);
            current = conn
                .resolve_drv_output(&sd, &translated, output_name)
                .await
                .unwrap()?;
        }
        Some(current)
    }

    /// Depth-1: unresolved.drv was resolved to resolved.drv, which has
    /// the outputs. The in-memory map translates before lookup.
    #[tokio::test]
    async fn resolve_with_map_depth_1() {
        let (_pg, mut conn) = setup().await;

        // resolved.drv was built successfully
        insert_step(&mut conn, 2, 1, &sp("resolved.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("result")).await;

        let mut map = std::collections::HashMap::new();
        map.insert(sp("unresolved.drv"), sp("resolved.drv"));

        let result =
            resolve_chain_with_map(&mut conn, &map, &sp("unresolved.drv"), &[&on("out")]).await;
        assert_eq!(result, Some(sp("result")));
    }

    /// Depth-2: unresolved.drv was resolved to resolved.drv, whose output
    /// is an intermediate.drv that has the final output.
    #[tokio::test]
    async fn resolve_with_map_depth_2() {
        let (_pg, mut conn) = setup().await;

        insert_step(&mut conn, 2, 1, &sp("resolved.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("intermediate.drv")).await;
        insert_step(&mut conn, 3, 1, &sp("intermediate.drv")).await;
        insert_output(&mut conn, 3, 1, "out", &sp("final")).await;

        let mut map = std::collections::HashMap::new();
        map.insert(sp("unresolved.drv"), sp("resolved.drv"));

        let result = resolve_chain_with_map(
            &mut conn,
            &map,
            &sp("unresolved.drv"),
            &[&on("out"), &on("out")],
        )
        .await;
        assert_eq!(result, Some(sp("final")));
    }

    /// Depth-2 where the intermediate result was also resolved:
    /// root.drv.drv (not resolved) → intermediate.drv (resolved) → final
    #[tokio::test]
    async fn resolve_with_map_intermediate_resolved() {
        let (_pg, mut conn) = setup().await;

        // root.drv.drv^out → unresolved-intermediate.drv
        insert_step(&mut conn, 1, 1, &sp("root.drv.drv")).await;
        insert_output(&mut conn, 1, 1, "out", &sp("unresolved-intermediate.drv")).await;

        // resolved-intermediate.drv^out → final-result
        insert_step(&mut conn, 2, 1, &sp("resolved-intermediate.drv")).await;
        insert_output(&mut conn, 2, 1, "out", &sp("final-result")).await;

        let mut map = std::collections::HashMap::new();
        map.insert(
            sp("unresolved-intermediate.drv"),
            sp("resolved-intermediate.drv"),
        );

        let result = resolve_chain_with_map(
            &mut conn,
            &map,
            &sp("root.drv.drv"),
            &[&on("out"), &on("out")],
        )
        .await;
        assert_eq!(result, Some(sp("final-result")));
    }

    async fn replica_conn(pool: &sqlx::PgPool) -> Connection {
        let mut conn = Connection::new(pool.acquire().await.unwrap());
        sqlx::raw_sql("SET session_replication_role = 'replica';")
            .execute(&mut *conn.conn)
            .await
            .unwrap();
        conn
    }

    fn substitution_step(build_id: i32, drv_path: &StorePath) -> InsertBuildStep<'_> {
        InsertBuildStep {
            build_id,
            r#type: crate::models::BuildType::Substitution,
            drv_path,
            status: BuildStatus::Success,
            busy: false,
            start_time: Some(0),
            stop_time: Some(0),
            platform: None,
            propagated_from: None,
            error_msg: None,
            machine: "",
        }
    }

    /// Two transactions inserting a step for the same build compute the same
    /// stepnr (MAX+1) while the first is still open. The second blocks on the
    /// unique index and, once the first commits, resolves to `None` via
    /// ON CONFLICT DO NOTHING. The caller retries; a fresh insert then picks
    /// the next number. The hot dispatch path avoids this collision with an
    /// in-process per-build lock in the queue runner.
    #[tokio::test]
    async fn concurrent_step_inserts_for_same_build_conflict() {
        let (_pg, pool) = test_utils::TestPg::new().await;
        let sd = test_store_dir();

        let mut conn_a = replica_conn(&pool).await;
        let mut conn_b = replica_conn(&pool).await;

        let mut tx_a = conn_a.begin_transaction().await.unwrap();
        let step_a = tx_a
            .insert_build_step(&sd, substitution_step(1, &sp("foo.drv")))
            .await
            .unwrap();
        assert_eq!(step_a, Some(1));

        let task_b = tokio::spawn(async move {
            let sd = test_store_dir();
            let mut tx_b = conn_b.begin_transaction().await.unwrap();
            let step = tx_b
                .insert_build_step(&sd, substitution_step(1, &sp("foo.drv")))
                .await
                .unwrap();
            tx_b.commit().await.unwrap();
            step
        });
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(
            !task_b.is_finished(),
            "concurrent insert should block on the unique index"
        );

        tx_a.commit().await.unwrap();

        // The blocked insert conflicts once the first transaction commits.
        assert_eq!(task_b.await.unwrap(), None);

        // After the conflict the caller retries; a fresh insert sees the
        // committed row and picks the next number.
        let mut tx_c = conn_a.begin_transaction().await.unwrap();
        let step_c = tx_c
            .insert_build_step(&sd, substitution_step(1, &sp("foo.drv")))
            .await
            .unwrap();
        tx_c.commit().await.unwrap();
        assert_eq!(step_c, Some(2));
    }

    /// A real Postgres deadlock (40P01) is classified as retryable.
    #[tokio::test]
    async fn deadlock_is_retryable_serialization_failure() {
        let (_pg, pool) = test_utils::TestPg::new().await;

        let mut setup = Connection::new(pool.acquire().await.unwrap());
        sqlx::raw_sql(
            "CREATE TABLE deadlock_test (id int PRIMARY KEY, v int);
             INSERT INTO deadlock_test VALUES (1, 0), (2, 0);",
        )
        .execute(&mut *setup.conn)
        .await
        .unwrap();

        let mut conn_a = Connection::new(pool.acquire().await.unwrap());
        let mut conn_b = Connection::new(pool.acquire().await.unwrap());

        let mut tx_a = conn_a.begin_transaction().await.unwrap();
        sqlx::query("UPDATE deadlock_test SET v = 1 WHERE id = 1")
            .execute(&mut *tx_a.tx)
            .await
            .unwrap();

        let mut tx_b = conn_b.begin_transaction().await.unwrap();
        sqlx::query("UPDATE deadlock_test SET v = 1 WHERE id = 2")
            .execute(&mut *tx_b.tx)
            .await
            .unwrap();

        // Each transaction now reaches for the row the other holds, closing the
        // cycle; Postgres aborts one of them with a deadlock error.
        let (res_a, res_b) = tokio::join!(
            sqlx::query("UPDATE deadlock_test SET v = 2 WHERE id = 2").execute(&mut *tx_a.tx),
            sqlx::query("UPDATE deadlock_test SET v = 2 WHERE id = 1").execute(&mut *tx_b.tx),
        );

        let victim = match (res_a, res_b) {
            (Err(e), Ok(_)) | (Ok(_), Err(e)) => crate::Error::from(e),
            (Err(_), Err(_)) => panic!("both transactions failed"),
            (Ok(_), Ok(_)) => panic!("expected a deadlock"),
        };
        assert!(
            victim.is_retryable_serialization_failure(),
            "deadlock error should be retryable: {victim:?}"
        );
    }
}

use sqlx::Acquire;

use super::models::{
    Build,
    BuildSmall,
    BuildStatus,
    BuildSteps,
    InsertBuildMetric,
    InsertBuildProduct,
    InsertBuildStep,
    InsertBuildStepOutput,
    Jobset,
    UpdateBuild,
    UpdateBuildStep,
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
    pub async fn begin_transaction(&mut self) -> sqlx::Result<Transaction<'_>> {
        let tx = self.conn.begin().await?;
        Ok(Transaction { tx })
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_not_finished_builds_fast(&mut self) -> sqlx::Result<Vec<BuildSmall>> {
        sqlx::query_as!(
            BuildSmall,
            r#"
            SELECT
              id,
              globalPriority
            FROM builds
            WHERE finished = 0;"#
        )
        .fetch_all(&mut *self.conn)
        .await
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_not_finished_builds(&mut self) -> sqlx::Result<Vec<Build>> {
        sqlx::query_as!(
            Build,
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
        .await
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_jobsets(&mut self) -> sqlx::Result<Vec<Jobset>> {
        sqlx::query_as!(
            Jobset,
            r#"
            SELECT
              project,
              name,
              schedulingshares
            FROM jobsets"#
        )
        .fetch_all(&mut *self.conn)
        .await
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_jobset_scheduling_shares(
        &mut self,
        jobset_id: i32,
    ) -> sqlx::Result<Option<i32>> {
        Ok(sqlx::query!(
            "SELECT schedulingshares FROM jobsets WHERE id = $1",
            jobset_id,
        )
        .fetch_optional(&mut *self.conn)
        .await?
        .map(|v| v.schedulingshares))
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_jobset_build_steps(
        &mut self,
        jobset_id: i32,
        scheduling_window: i64,
    ) -> sqlx::Result<Vec<BuildSteps>> {
        #[allow(clippy::cast_precision_loss)]
        sqlx::query_as!(
            BuildSteps,
            r#"
            SELECT s.startTime, s.stopTime FROM buildsteps s join builds b on build = id
            WHERE
              s.startTime IS NOT NULL AND
              to_timestamp(s.stopTime) > (NOW() - (interval '1 second' * $1)) AND
              jobset_id = $2
            "#,
            Some((scheduling_window * 10) as f64),
            jobset_id,
        )
        .fetch_all(&mut *self.conn)
        .await
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn abort_build(&mut self, build_id: i32) -> sqlx::Result<()> {
        #[allow(clippy::cast_possible_truncation)]
        sqlx::query!(
            "UPDATE builds SET finished = 1, buildStatus = $2, startTime = $3, stopTime = $3 \
             where id = $1 and finished = 0",
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
    pub async fn check_if_paths_failed(&mut self, paths: &[String]) -> sqlx::Result<bool> {
        Ok(
            !sqlx::query!("SELECT path FROM failedpaths where path = ANY($1)", paths)
                .fetch_all(&mut *self.conn)
                .await?
                .is_empty(),
        )
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn clear_busy(&mut self, stop_time: i32) -> sqlx::Result<()> {
        sqlx::query!(
            "UPDATE buildsteps SET busy = 0, status = $1, stopTime = $2 WHERE busy != 0;",
            BuildStatus::Aborted as i32,
            Some(stop_time),
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, step), err)]
    pub async fn update_build_step(&mut self, step: UpdateBuildStep) -> sqlx::Result<()> {
        sqlx::query!(
            "UPDATE buildsteps SET busy = $1 WHERE build = $2 AND stepnr = $3 AND busy != 0 AND \
             status IS NULL",
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
        jobset_id: i32,
        drv_path: &str,
        system: &str,
    ) -> sqlx::Result<()> {
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
        out_path: &str,
    ) -> sqlx::Result<Option<super::models::BuildOutput>> {
        sqlx::query_as!(
            super::models::BuildOutput,
            r#"
            SELECT
              id, buildStatus, releaseName, closureSize, size
            FROM builds b
            JOIN buildoutputs o on b.id = o.build
            WHERE finished = 1 and (buildStatus = 0 or buildStatus = 6) and path = $1;"#,
            out_path,
        )
        .fetch_optional(&mut *self.conn)
        .await
    }

    pub async fn get_build_products_for_build_id(
        &mut self,
        build_id: i32,
    ) -> sqlx::Result<Vec<crate::models::OwnedBuildProduct>> {
        sqlx::query_as!(
            super::models::OwnedBuildProduct,
            r#"
            SELECT
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
        .await
    }

    pub async fn get_build_metrics_for_build_id(
        &mut self,
        build_id: i32,
    ) -> sqlx::Result<Vec<crate::models::OwnedBuildMetric>> {
        sqlx::query_as!(
            crate::models::OwnedBuildMetric,
            r#"
            SELECT
              name, unit, value
            FROM buildmetrics
            WHERE build = $1;"#,
            build_id
        )
        .fetch_all(&mut *self.conn)
        .await
    }

    /// Resolve output paths for derivation chains via `buildstepoutputs`.
    ///
    /// Each entry is `(root_drv_path, &[output_name, ...])` representing a
    /// chain like `root.drv^out1^out2`. The recursive CTE walks the chain:
    /// look up `root.drv`'s `out1` output to get an intermediate drv path,
    /// then look up that drv's `out2`, etc. Returns the final resolved path
    /// for each chain (or `None` if any step fails).
    pub async fn resolve_drv_output_chains(
        &mut self,
        chains: &[(&str, &[&str])],
    ) -> sqlx::Result<Vec<Option<String>>> {
        if chains.is_empty() {
            return Ok(Vec::new());
        }

        // We pack as JSON here since sqlx can't bind `text[][]` directly.
        let json_input = serde_json::Value::Array(
            chains
                .iter()
                .map(|(root, outputs)| {
                    serde_json::json!({
                        "root": root,
                        "chain": outputs,
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
            results[(idx - 1) as usize] = path;
        }
        Ok(results)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_status(&mut self) -> sqlx::Result<Option<serde_json::Value>> {
        Ok(
            sqlx::query!("SELECT status FROM systemstatus WHERE what = 'queue-runner';",)
                .fetch_optional(&mut *self.conn)
                .await?
                .map(|v| v.status),
        )
    }
}

impl Transaction<'_> {
    #[tracing::instrument(skip(self), err)]
    pub async fn commit(self) -> sqlx::Result<()> {
        self.tx.commit().await
    }

    #[tracing::instrument(skip(self, v), err)]
    pub async fn update_build(&mut self, build_id: i32, v: UpdateBuild<'_>) -> sqlx::Result<()> {
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
    ) -> sqlx::Result<()> {
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
    ) -> sqlx::Result<()> {
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
        build_id: i32,
        name: &str,
        path: &str,
    ) -> sqlx::Result<()> {
        // TODO: support inserting multiple at the same time
        sqlx::query!(
            "UPDATE buildoutputs SET path = $3 WHERE build = $1 AND name = $2",
            build_id,
            name,
            path,
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_last_build_step_id(&mut self, path: &str) -> sqlx::Result<Option<i32>> {
        Ok(sqlx::query!(
            "SELECT MAX(build) FROM buildsteps WHERE drvPath = $1 and startTime != 0 and stopTime \
             != 0 and status = 1",
            path
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn get_last_build_step_id_for_output_path(
        &mut self,
        path: &str,
    ) -> sqlx::Result<Option<i32>> {
        Ok(sqlx::query!(
            r#"
                  SELECT MAX(s.build) FROM buildsteps s
                  JOIN BuildStepOutputs o ON s.build = o.build
                  WHERE startTime != 0
                    AND stopTime != 0
                    AND status = 1
                    AND path = $1
                "#,
            path,
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self, drv_path, name), err)]
    pub async fn get_last_build_step_id_for_output_with_drv(
        &mut self,
        drv_path: &str,
        name: &str,
    ) -> sqlx::Result<Option<i32>> {
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

    #[tracing::instrument(skip(self), err)]
    pub async fn alloc_build_step(&mut self, build_id: i32) -> sqlx::Result<i32> {
        Ok(sqlx::query!(
            "SELECT MAX(stepnr) FROM buildsteps WHERE build = $1",
            build_id
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .and_then(|v| v.max)
        .map_or(1, |v| v + 1))
    }

    #[tracing::instrument(skip(self, step), err)]
    pub async fn insert_build_step(&mut self, step: InsertBuildStep<'_>) -> sqlx::Result<bool> {
        let success = sqlx::query!(
            r#"
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
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
              )
              ON CONFLICT DO NOTHING
            "#,
            step.build_id,
            step.step_nr,
            step.r#type as i32,
            step.drv_path,
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
        .execute(&mut *self.tx)
        .await?
        .rows_affected()
            != 0;
        Ok(success)
    }

    #[tracing::instrument(skip(self, outputs), err)]
    pub async fn insert_build_step_outputs(
        &mut self,
        outputs: &[InsertBuildStepOutput],
    ) -> sqlx::Result<()> {
        if outputs.is_empty() {
            return Ok(());
        }

        let mut query_builder =
            sqlx::QueryBuilder::new("INSERT INTO buildstepoutputs (build, stepnr, name, path) ");

        query_builder.push_values(outputs, |mut b, output| {
            b.push_bind(output.build_id)
                .push_bind(output.step_nr)
                .push_bind(&output.name)
                .push_bind(&output.path);
        });
        let query = query_builder.build();
        query.execute(&mut *self.tx).await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, name, path), err)]
    pub async fn update_build_step_output(
        &mut self,
        build_id: i32,
        step_nr: i32,
        name: &str,
        path: &str,
    ) -> sqlx::Result<()> {
        // TODO: support inserting multiple at the same time
        sqlx::query!(
            "UPDATE buildstepoutputs SET path = $4 WHERE build = $1 AND stepnr = $2 AND name = $3",
            build_id,
            step_nr,
            name,
            path,
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, res), err)]
    pub async fn update_build_step_in_finish(
        &mut self,
        res: UpdateBuildStepInFinish<'_>,
    ) -> sqlx::Result<()> {
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
        build_id: i32,
        step_nr: i32,
    ) -> sqlx::Result<Option<String>> {
        Ok(sqlx::query!(
            "SELECT drvPath FROM BuildSteps WHERE build = $1 AND stepnr = $2",
            build_id,
            step_nr
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .and_then(|v| v.drvpath))
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn check_if_build_is_not_finished(&mut self, build_id: i32) -> sqlx::Result<bool> {
        Ok(sqlx::query!(
            "SELECT id FROM builds WHERE id = $1 AND finished = 0",
            build_id,
        )
        .fetch_optional(&mut *self.tx)
        .await?
        .is_some())
    }

    #[tracing::instrument(skip(self, p), err)]
    pub async fn insert_build_product(&mut self, p: InsertBuildProduct<'_>) -> sqlx::Result<()> {
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
            p.sha256hash,
            p.path,
            p.name,
            p.default_path,
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn delete_build_products_by_build_id(&mut self, build_id: i32) -> sqlx::Result<()> {
        sqlx::query!("DELETE FROM buildproducts WHERE build = $1", build_id)
            .execute(&mut *self.tx)
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, metric), err)]
    pub async fn insert_build_metric(&mut self, metric: InsertBuildMetric<'_>) -> sqlx::Result<()> {
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
    pub async fn delete_build_metrics_by_build_id(&mut self, build_id: i32) -> sqlx::Result<()> {
        sqlx::query!("DELETE FROM buildmetrics WHERE build = $1", build_id)
            .execute(&mut *self.tx)
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, path), err)]
    pub async fn insert_failed_paths(&mut self, path: &str) -> sqlx::Result<()> {
        sqlx::query!(
            r#"
              INSERT INTO failedpaths (
                path
              ) VALUES (
                $1
              )
            "#,
            path,
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
        start_time: Option<i32>,
        build_id: crate::models::BuildID,
        drv_path: &str,
        platform: Option<&str>,
        machine: String,
        status: BuildStatus,
        error_msg: Option<String>,
        propagated_from: Option<crate::models::BuildID>,
        outputs: Vec<(String, Option<String>)>,
    ) -> sqlx::Result<i32> {
        let step_nr = loop {
            let step_nr = self.alloc_build_step(build_id).await?;
            if self
                .insert_build_step(InsertBuildStep {
                    build_id,
                    step_nr,
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
                })
                .await?
            {
                break step_nr;
            }
        };

        self.insert_build_step_outputs(
            &outputs
                .into_iter()
                .map(|(name, path)| {
                    InsertBuildStepOutput {
                        build_id,
                        step_nr,
                        name,
                        path,
                    }
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
        skip(self, start_time, stop_time, build_id, drv_path, output,),
        err,
        ret
    )]
    pub async fn create_substitution_step(
        &mut self,
        start_time: i32,
        stop_time: i32,
        build_id: crate::models::BuildID,
        drv_path: &str,
        output: (String, Option<String>),
    ) -> anyhow::Result<i32> {
        let step_nr = loop {
            let step_nr = self.alloc_build_step(build_id).await?;
            if self
                .insert_build_step(InsertBuildStep {
                    build_id,
                    step_nr,
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
                })
                .await?
            {
                break step_nr;
            }
        };

        self.insert_build_step_outputs(&[InsertBuildStepOutput {
            build_id,
            step_nr,
            name: output.0,
            path: output.1,
        }])
        .await?;

        Ok(step_nr)
    }

    #[tracing::instrument(skip(self, build, is_cached_build, start_time, stop_time,), err)]
    pub async fn mark_succeeded_build(
        &mut self,
        build: crate::models::MarkBuildSuccessData<'_>,
        is_cached_build: bool,
        start_time: i32,
        stop_time: i32,
    ) -> anyhow::Result<()> {
        if build.finished_in_db {
            return Ok(());
        }

        if !self.check_if_build_is_not_finished(build.id).await? {
            return Ok(());
        }

        self.update_build(build.id, UpdateBuild {
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
        })
        .await?;

        for (name, path) in &build.outputs {
            self.update_build_output(build.id, name, path).await?;
        }

        self.delete_build_products_by_build_id(build.id).await?;

        for (nr, p) in build.products.iter().enumerate() {
            self.insert_build_product(InsertBuildProduct {
                build_id:     build.id,
                product_nr:   i32::try_from(nr + 1)?,
                r#type:       p.r#type,
                subtype:      p.subtype,
                file_size:    p.filesize,
                sha256hash:   p.sha256hash,
                path:         p.path.as_deref().unwrap_or_default(),
                name:         p.name,
                default_path: p.defaultpath.unwrap_or_default(),
            })
            .await?;
        }

        self.delete_build_metrics_by_build_id(build.id).await?;
        for m in &build.metrics {
            self.insert_build_metric(InsertBuildMetric {
                build_id:  build.id,
                name:      m.name,
                unit:      m.unit,
                value:     m.value,
                project:   build.project_name,
                jobset:    build.jobset_name,
                job:       build.name,
                timestamp: i32::try_from(build.timestamp)?, // TODO
            })
            .await?;
        }
        Ok(())
    }

    #[tracing::instrument(skip(self, status), err)]
    pub async fn upsert_status(&mut self, status: &serde_json::Value) -> sqlx::Result<()> {
        sqlx::query!(
            r#"INSERT INTO systemstatus (
              what, status
            ) VALUES (
              'queue-runner', $1
            ) ON CONFLICT (what) DO UPDATE SET status = EXCLUDED.status;"#,
            Some(status),
        )
        .execute(&mut *self.tx)
        .await?;
        Ok(())
    }
}

impl Transaction<'_> {
    #[tracing::instrument(skip(self), err)]
    async fn notify_any(&mut self, channel: &str, msg: &str) -> sqlx::Result<()> {
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
    pub async fn notify_builds_added(&mut self) -> sqlx::Result<()> {
        self.notify_any("builds_added", "?").await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn notify_build_started(&mut self, build_id: i32) -> sqlx::Result<()> {
        self.notify_any("build_started", &build_id.to_string())
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id, dependent_ids,), err)]
    pub async fn notify_build_finished(
        &mut self,
        build_id: i32,
        dependent_ids: &[i32],
    ) -> sqlx::Result<()> {
        let mut q = vec![build_id.to_string()];
        q.extend(dependent_ids.iter().map(ToString::to_string));

        self.notify_any("build_finished", &q.join("\t")).await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, build_id, step_nr,), err)]
    pub async fn notify_step_started(&mut self, build_id: i32, step_nr: i32) -> sqlx::Result<()> {
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
    ) -> sqlx::Result<()> {
        self.notify_any(
            "step_finished",
            &format!("{build_id}\t{step_nr}\t{log_file}"),
        )
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn notify_dump_status(&mut self) -> sqlx::Result<()> {
        self.notify_any("dump_status", "").await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn notify_status_dumped(&mut self) -> sqlx::Result<()> {
        self.notify_any("status_dumped", "").await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    async fn setup() -> (test_utils::TestPg, Connection) {
        let (pg, pool) = test_utils::TestPg::new().await;
        let mut conn = Connection::new(pool.acquire().await.unwrap());
        sqlx::raw_sql("SET session_replication_role = 'replica';")
            .execute(&mut *conn.conn)
            .await
            .unwrap();
        (pg, conn)
    }

    async fn insert_step(conn: &mut Connection, build: i32, stepnr: i32, drv_path: &str) {
        sqlx::query(
            "INSERT INTO BuildSteps (build, stepnr, type, busy, drvPath, status) VALUES ($1, $2, \
             0, 0, $3, 0)",
        )
        .bind(build)
        .bind(stepnr)
        .bind(drv_path)
        .execute(&mut *conn.conn)
        .await
        .unwrap();
    }

    async fn insert_output(conn: &mut Connection, build: i32, stepnr: i32, name: &str, path: &str) {
        sqlx::query(
            "INSERT INTO BuildStepOutputs (build, stepnr, name, path) VALUES ($1, $2, $3, $4)",
        )
        .bind(build)
        .bind(stepnr)
        .bind(name)
        .bind(path)
        .execute(&mut *conn.conn)
        .await
        .unwrap();
    }

    #[tokio::test]
    async fn resolve_depth_1() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, "/nix/store/aaa-foo.drv").await;
        insert_output(&mut conn, 1, 1, "out", "/nix/store/bbb-result").await;

        let results = conn
            .resolve_drv_output_chains(&[("/nix/store/aaa-foo.drv", &["out"])])
            .await
            .unwrap();
        assert_eq!(results, vec![Some("/nix/store/bbb-result".into())]);
    }

    #[tokio::test]
    async fn resolve_depth_2() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, "/nix/store/aaa-foo.drv").await;
        insert_output(&mut conn, 1, 1, "out", "/nix/store/bbb-bar.drv").await;
        insert_step(&mut conn, 2, 1, "/nix/store/bbb-bar.drv").await;
        insert_output(&mut conn, 2, 1, "dev", "/nix/store/ccc-final").await;

        let results = conn
            .resolve_drv_output_chains(&[("/nix/store/aaa-foo.drv", &["out", "dev"])])
            .await
            .unwrap();
        assert_eq!(results, vec![Some("/nix/store/ccc-final".into())]);
    }

    #[tokio::test]
    async fn resolve_batch() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, "/nix/store/aaa-foo.drv").await;
        insert_output(&mut conn, 1, 1, "out", "/nix/store/bbb-foo-out").await;
        insert_step(&mut conn, 2, 1, "/nix/store/ccc-bar.drv").await;
        insert_output(&mut conn, 2, 1, "lib", "/nix/store/ddd-bar-lib").await;

        let results = conn
            .resolve_drv_output_chains(&[
                ("/nix/store/aaa-foo.drv", &["out"]),
                ("/nix/store/ccc-bar.drv", &["lib"]),
            ])
            .await
            .unwrap();
        assert_eq!(results, vec![
            Some("/nix/store/bbb-foo-out".into()),
            Some("/nix/store/ddd-bar-lib".into()),
        ]);
    }

    #[tokio::test]
    async fn resolve_missing() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, "/nix/store/aaa-foo.drv").await;
        insert_output(&mut conn, 1, 1, "out", "/nix/store/bbb-result").await;

        let results = conn
            .resolve_drv_output_chains(&[
                ("/nix/store/aaa-foo.drv", &["out"]),
                ("/nix/store/nonexistent.drv", &["out"]),
            ])
            .await
            .unwrap();
        assert_eq!(results, vec![Some("/nix/store/bbb-result".into()), None]);
    }

    #[tokio::test]
    async fn resolve_empty() {
        let (_pg, mut conn) = setup().await;
        let results = conn.resolve_drv_output_chains(&[]).await.unwrap();
        assert!(results.is_empty());
    }

    #[tokio::test]
    async fn resolve_picks_latest_build() {
        let (_pg, mut conn) = setup().await;
        insert_step(&mut conn, 1, 1, "/nix/store/aaa-foo.drv").await;
        insert_output(&mut conn, 1, 1, "out", "/nix/store/old-result").await;
        insert_step(&mut conn, 5, 1, "/nix/store/aaa-foo.drv").await;
        insert_output(&mut conn, 5, 1, "out", "/nix/store/new-result").await;

        let results = conn
            .resolve_drv_output_chains(&[("/nix/store/aaa-foo.drv", &["out"])])
            .await
            .unwrap();
        assert_eq!(results, vec![Some("/nix/store/new-result".into())]);
    }

    /// Batch with ragged depths: one depth-1 (Opaque), one depth-2 (Built),
    /// one depth-3 (Built(Built(...))).
    #[tokio::test]
    async fn resolve_ragged_batch() {
        let (_pg, mut conn) = setup().await;

        // Depth 1: aaa.drv ^out => result-a
        insert_step(&mut conn, 1, 1, "/nix/store/aaa.drv").await;
        insert_output(&mut conn, 1, 1, "out", "/nix/store/result-a").await;

        // Depth 2: bbb.drv ^out => ccc.drv, ccc.drv ^lib => result-b
        insert_step(&mut conn, 2, 1, "/nix/store/bbb.drv").await;
        insert_output(&mut conn, 2, 1, "out", "/nix/store/ccc.drv").await;
        insert_step(&mut conn, 3, 1, "/nix/store/ccc.drv").await;
        insert_output(&mut conn, 3, 1, "lib", "/nix/store/result-b").await;

        // Depth 3: ddd.drv ^out => eee.drv, eee.drv ^dev => fff.drv, fff.drv ^bin =>
        // result-c
        insert_step(&mut conn, 4, 1, "/nix/store/ddd.drv").await;
        insert_output(&mut conn, 4, 1, "out", "/nix/store/eee.drv").await;
        insert_step(&mut conn, 5, 1, "/nix/store/eee.drv").await;
        insert_output(&mut conn, 5, 1, "dev", "/nix/store/fff.drv").await;
        insert_step(&mut conn, 6, 1, "/nix/store/fff.drv").await;
        insert_output(&mut conn, 6, 1, "bin", "/nix/store/result-c").await;

        let results = conn
            .resolve_drv_output_chains(&[
                ("/nix/store/aaa.drv", &["out"]),
                ("/nix/store/bbb.drv", &["out", "lib"]),
                ("/nix/store/ddd.drv", &["out", "dev", "bin"]),
            ])
            .await
            .unwrap();
        assert_eq!(results, vec![
            Some("/nix/store/result-a".into()),
            Some("/nix/store/result-b".into()),
            Some("/nix/store/result-c".into()),
        ]);
    }
}

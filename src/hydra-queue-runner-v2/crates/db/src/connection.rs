use sqlx::Acquire;

use super::models::{
    Build, BuildSmall, BuildStatus, BuildSteps, InsertBuildMetric, InsertBuildProduct,
    InsertBuildStep, InsertBuildStepOutput, Jobset, UpdateBuild, UpdateBuildStep,
    UpdateBuildStepInFinish,
};

pub struct Connection {
    conn: sqlx::pool::PoolConnection<sqlx::Postgres>,
}

pub struct Transaction<'a> {
    tx: sqlx::PgTransaction<'a>,
}

impl Connection {
    pub fn new(conn: sqlx::pool::PoolConnection<sqlx::Postgres>) -> Self {
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
            "UPDATE builds SET finished = 1, buildStatus = $2, startTime = $3, stopTime = $3 where id = $1 and finished = 0",
            build_id,
            BuildStatus::Aborted as i32,
            // TODO migrate to 64bit timestamp
            chrono::Utc::now().timestamp() as i32,
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
            chrono::Utc::now().timestamp() as i32,
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
        Ok(sqlx::query!("SELECT MAX(build) FROM buildsteps WHERE drvPath = $1 and startTime != 0 and stopTime != 0 and status = 1", path)
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
        start_time: Option<i64>,
        build_id: crate::models::BuildID,
        drv_path: &str,
        platform: Option<&str>,
        machine: String,
        status: crate::models::BuildStatus,
        error_msg: Option<String>,
        propagated_from: Option<crate::models::BuildID>,
        outputs: Vec<(String, Option<String>)>,
    ) -> sqlx::Result<i32> {
        let start_time = start_time.and_then(|start_time| i32::try_from(start_time).ok()); // TODO

        let step_nr = loop {
            let step_nr = self.alloc_build_step(build_id).await?;
            if self
                .insert_build_step(crate::models::InsertBuildStep {
                    build_id,
                    step_nr,
                    r#type: crate::models::BuildType::Build,
                    drv_path,
                    status,
                    busy: status == crate::models::BuildStatus::Busy,
                    start_time,
                    stop_time: if status == crate::models::BuildStatus::Busy {
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
                .map(|(name, path)| crate::models::InsertBuildStepOutput {
                    build_id,
                    step_nr,
                    name,
                    path,
                })
                .collect::<Vec<_>>(),
        )
        .await?;

        if status == crate::models::BuildStatus::Busy {
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
                .insert_build_step(crate::models::InsertBuildStep {
                    build_id,
                    step_nr,
                    r#type: crate::models::BuildType::Substitution,
                    drv_path,
                    status: crate::models::BuildStatus::Success,
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

        self.insert_build_step_outputs(&[crate::models::InsertBuildStepOutput {
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

        self.update_build(
            build.id,
            crate::models::UpdateBuild {
                status: if build.failed {
                    crate::models::BuildStatus::FailedWithOutput
                } else {
                    crate::models::BuildStatus::Success
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
            self.update_build_output(build.id, name, path).await?;
        }

        self.delete_build_products_by_build_id(build.id).await?;

        for (nr, p) in build.products.iter().enumerate() {
            self.insert_build_product(crate::models::InsertBuildProduct {
                build_id: build.id,
                product_nr: i32::try_from(nr + 1)?,
                r#type: p.r#type,
                subtype: p.subtype,
                file_size: p.filesize,
                sha256hash: p.sha256hash,
                path: p.path.as_deref().unwrap_or_default(),
                name: p.name,
                default_path: p.defaultpath.unwrap_or_default(),
            })
            .await?;
        }

        self.delete_build_metrics_by_build_id(build.id).await?;
        for m in &build.metrics {
            self.insert_build_metric(crate::models::InsertBuildMetric {
                build_id: build.id,
                name: m.1.name,
                unit: m.1.unit,
                value: m.1.value,
                project: build.project_name,
                jobset: build.jobset_name,
                job: build.name,
                timestamp: i32::try_from(build.timestamp.timestamp())?, // TODO
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

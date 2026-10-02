use std::collections::BTreeMap;

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};

use super::{Handle, Transaction, names_and_paths};
use crate::models::{
    BuildID, BuildStatus, BuildType, InsertBuildStep, UpdateBuildStep, UpdateBuildStepInFinish,
};

impl<C: std::ops::DerefMut<Target = sqlx::PgConnection>> Handle<C> {
    #[tracing::instrument(skip_all, err)]
    pub async fn check_if_paths_failed(
        &mut self,
        store_dir: &StoreDir,
        paths: &[&StorePath],
    ) -> crate::Result<bool> {
        let paths: Vec<String> = paths
            .iter()
            .map(|p| store_dir.display(*p).to_string())
            .collect();
        if paths.is_empty() {
            return Ok(false);
        }
        Ok(sqlx::query_scalar!(
            r#"SELECT EXISTS (SELECT 1 FROM failedpaths WHERE path = ANY($1)) AS "exists!""#,
            &paths
        )
        .fetch_one(&mut *self.conn)
        .await?)
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn clear_busy(&mut self, stop_time: crate::Timestamp) -> crate::Result<()> {
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
        build_id: BuildID,
        step_nr: i32,
        stop_time: crate::Timestamp,
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

    #[tracing::instrument(skip(self, store_dir), err)]
    pub async fn get_last_build_step_id(
        &mut self,
        store_dir: &StoreDir,
        path: &StorePath,
    ) -> crate::Result<Option<BuildID>> {
        let path = store_dir.display(path).to_string();
        Ok(sqlx::query!("SELECT MAX(build) FROM buildsteps WHERE drvPath = $1 and startTime != 0 and stopTime != 0 and status = 1", path.as_str())
            .fetch_optional(&mut *self.conn)
            .await?
            .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self, store_dir), err)]
    pub async fn get_last_build_step_id_for_output_path(
        &mut self,
        store_dir: &StoreDir,
        path: &StorePath,
    ) -> crate::Result<Option<BuildID>> {
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
        .fetch_optional(&mut *self.conn)
        .await?
        .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self, store_dir, drv_path, name), err)]
    pub async fn get_last_build_step_id_for_output_with_drv(
        &mut self,
        store_dir: &StoreDir,
        drv_path: &StorePath,
        name: &str,
    ) -> crate::Result<Option<BuildID>> {
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
        .fetch_optional(&mut *self.conn)
        .await?
        .and_then(|v| v.max))
    }

    #[tracing::instrument(skip(self, store_dir, outputs), err)]
    pub async fn update_build_step_outputs(
        &mut self,
        store_dir: &StoreDir,
        build_id: BuildID,
        step_nr: i32,
        outputs: &BTreeMap<OutputName, StorePath>,
    ) -> crate::Result<()> {
        let (names, paths) = names_and_paths(store_dir, outputs);
        sqlx::query!(
            "UPDATE buildstepoutputs o SET path = v.path
             FROM UNNEST($3::text[], $4::text[]) AS v(name, path)
             WHERE o.build = $1 AND o.stepnr = $2 AND o.name = v.name",
            build_id,
            step_nr,
            &names,
            &paths,
        )
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, store_dir), err)]
    pub async fn find_build_step_outputs(
        &mut self,
        store_dir: &StoreDir,
        drv_path: &StorePath,
    ) -> crate::Result<BTreeMap<OutputName, StorePath>> {
        let drv_path = store_dir.display(drv_path).to_string();
        let items = sqlx::query!(
            r#"SELECT DISTINCT ON (o.name) o.name, o.path AS "path!"
              FROM buildstepoutputs o
              JOIN buildsteps s ON s.build = o.build AND s.stepnr = o.stepnr
              WHERE s.drvpath = $1 AND o.path IS NOT NULL
              ORDER BY o.name, s.build DESC, s.stepnr DESC"#,
            drv_path,
        )
        .fetch_all(&mut *self.conn)
        .await?;

        items
            .into_iter()
            .map(|row| -> crate::Result<_> {
                let name: OutputName = row.name.parse()?;
                let path: StorePath = store_dir.parse(&row.path)?;
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
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self, store_dir, build_id, step_nr), err)]
    pub async fn get_drv_path_from_build_step(
        &mut self,
        store_dir: &StoreDir,
        build_id: BuildID,
        step_nr: i32,
    ) -> crate::Result<Option<StorePath>> {
        Ok(sqlx::query!(
            "SELECT drvPath FROM BuildSteps WHERE build = $1 AND stepnr = $2",
            build_id,
            step_nr
        )
        .fetch_optional(&mut *self.conn)
        .await?
        .map(|v| store_dir.parse(&v.drvpath))
        .transpose()?)
    }

    #[tracing::instrument(skip(self, store_dir, path), err)]
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
        .execute(&mut *self.conn)
        .await?;
        Ok(())
    }
}

impl Transaction<'_> {
    #[tracing::instrument(skip(self, store_dir, step), err)]
    async fn insert_build_step(
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
                machine,
                resolvedDrvPath
              ) VALUES (
                $1, (SELECT val FROM new_stepnr), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12
              )
              ON CONFLICT DO NOTHING
              RETURNING stepnr
            "#,
            step.build_id,
            step.r#type as i32,
            drv_path.as_str(),
            i32::from(step.status == BuildStatus::Busy),
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
            step.resolved_drv_path.map(ToString::to_string),
        )
        .fetch_optional(&mut *self.conn)
        .await?
        .map(|v| v.stepnr);
        Ok(success)
    }

    #[tracing::instrument(skip(self, store_dir, outputs), err)]
    async fn insert_build_step_outputs(
        &mut self,
        store_dir: &StoreDir,
        build_id: BuildID,
        step_nr: i32,
        outputs: impl IntoIterator<Item = (OutputName, Option<StorePath>)>,
    ) -> crate::Result<()> {
        let mut outputs = outputs.into_iter().peekable();
        if outputs.peek().is_none() {
            return Ok(());
        }

        let mut query_builder =
            sqlx::QueryBuilder::new("INSERT INTO buildstepoutputs (build, stepnr, name, path) ");

        query_builder.push_values(outputs, |mut b, (name, path)| {
            b.push_bind(build_id)
                .push_bind(step_nr)
                .push_bind(name.to_string())
                .push_bind(path.map(|p| store_dir.display(&p).to_string()));
        });
        let query = query_builder.build();
        query.execute(&mut *self.conn).await?;
        Ok(())
    }

    /// Insert `step`, retrying on a `stepnr` conflict, then insert its outputs.
    async fn insert_build_step_with_outputs(
        &mut self,
        store_dir: &StoreDir,
        step: InsertBuildStep<'_>,
        outputs: impl IntoIterator<Item = (OutputName, Option<StorePath>)>,
    ) -> crate::Result<i32> {
        let step_nr = loop {
            if let Some(step_nr) = self.insert_build_step(store_dir, step).await? {
                break step_nr;
            }
        };
        self.insert_build_step_outputs(store_dir, step.build_id, step_nr, outputs)
            .await?;
        Ok(step_nr)
    }

    /// Create a build step with its outputs. A [`Busy`](BuildStatus::Busy)
    /// step stays open, and this sends `step_started` for it. Any other
    /// status finishes the step at `start_time`.
    #[allow(clippy::too_many_arguments)]
    #[tracing::instrument(skip_all, fields(build_id, %drv_path, ?status), err)]
    pub async fn create_build_step(
        &mut self,
        store_dir: &StoreDir,
        start_time: Option<crate::Timestamp>,
        build_id: BuildID,
        drv_path: &StorePath,
        platform: Option<&str>,
        machine: &str,
        status: BuildStatus,
        error_msg: Option<&str>,
        propagated_from: Option<BuildID>,
        outputs: BTreeMap<OutputName, Option<StorePath>>,
    ) -> crate::Result<i32> {
        let busy = status == BuildStatus::Busy;
        let step = InsertBuildStep {
            build_id,
            r#type: BuildType::Build,
            drv_path,
            status,
            start_time,
            stop_time: if busy { None } else { start_time },
            platform,
            propagated_from,
            error_msg,
            machine,
            resolved_drv_path: None,
        };
        let step_nr = self
            .insert_build_step_with_outputs(store_dir, step, outputs)
            .await?;
        if busy {
            self.notify_step_started(build_id, step_nr).await?;
        }
        Ok(step_nr)
    }

    /// Create a build step recording that `drv_path` was resolved to
    /// `resolved_drv_path`, along with its outputs. The counterpart of
    /// [`create_build_step`](Self::create_build_step) for steps with status
    /// [`Resolved`](BuildStatus::Resolved).
    #[allow(clippy::too_many_arguments)]
    #[tracing::instrument(skip_all, fields(build_id, %drv_path, %resolved_drv_path), err)]
    pub async fn create_resolved_build_step(
        &mut self,
        store_dir: &StoreDir,
        start_time: crate::Timestamp,
        build_id: BuildID,
        drv_path: &StorePath,
        platform: Option<&str>,
        machine: &str,
        resolved_drv_path: &StorePath,
        outputs: BTreeMap<OutputName, Option<StorePath>>,
    ) -> crate::Result<i32> {
        let step = InsertBuildStep {
            build_id,
            r#type: BuildType::Build,
            drv_path,
            status: BuildStatus::Resolved,
            start_time: Some(start_time),
            stop_time: Some(start_time),
            platform,
            propagated_from: None,
            error_msg: None,
            machine,
            resolved_drv_path: Some(resolved_drv_path),
        };
        self.insert_build_step_with_outputs(store_dir, step, outputs)
            .await
    }

    /// Create a finished step for outputs that the queue runner substituted
    /// or found already valid locally, instead of building them.
    #[tracing::instrument(skip_all, fields(build_id, %drv_path), err, ret)]
    pub async fn create_substitution_step(
        &mut self,
        store_dir: &StoreDir,
        start_time: crate::Timestamp,
        stop_time: crate::Timestamp,
        build_id: BuildID,
        drv_path: &StorePath,
        outputs: BTreeMap<OutputName, StorePath>,
    ) -> crate::Result<i32> {
        let step = InsertBuildStep {
            build_id,
            r#type: BuildType::Substitution,
            drv_path,
            status: BuildStatus::Success,
            start_time: Some(start_time),
            stop_time: Some(stop_time),
            platform: None,
            propagated_from: None,
            error_msg: None,
            machine: "",
            resolved_drv_path: None,
        };
        self.insert_build_step_with_outputs(
            store_dir,
            step,
            outputs.into_iter().map(|(name, path)| (name, Some(path))),
        )
        .await
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::Connection;
    use crate::connection::test_helpers::{replica_conn, setup, sp, test_store_dir};

    #[tokio::test]
    async fn clear_busy_step_finalizes_only_the_named_step() {
        async fn insert_busy(conn: &mut Connection, build: BuildID, stepnr: i32, drv: &StorePath) {
            sqlx::query!(
                "INSERT INTO BuildSteps (build, stepnr, type, busy, drvPath, status) VALUES ($1, $2, 0, 1, $3, NULL)",
                build,
                stepnr,
                test_store_dir().display(drv).to_string(),
            )
                .execute(&mut *conn.conn)
                .await
                .unwrap();
        }

        async fn busy_status(
            conn: &mut Connection,
            build: BuildID,
            stepnr: i32,
        ) -> (i32, Option<i32>) {
            let row = sqlx::query!(
                "SELECT busy, status FROM buildsteps WHERE build = $1 AND stepnr = $2",
                build,
                stepnr,
            )
            .fetch_one(&mut *conn.conn)
            .await
            .unwrap();
            (row.busy, row.status)
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

    fn substitution_step(build_id: BuildID, drv_path: &StorePath) -> InsertBuildStep<'_> {
        InsertBuildStep {
            build_id,
            r#type: BuildType::Substitution,
            drv_path,
            status: BuildStatus::Success,
            start_time: Some(0),
            stop_time: Some(0),
            platform: None,
            propagated_from: None,
            error_msg: None,
            machine: "",
            resolved_drv_path: None,
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
}

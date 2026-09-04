//! Compile-time-checked queries over the jobset-scheduling slice of the
//! schema, as an extension trait on [`db::Connection`]. These live here
//! rather than in the shared `db` crate because this part of the schema
//! is only relevant to the evaluator; the `db` crate provides the pooled
//! connection (with its acquire-retry) via [`db::Database::get`].

use sqlx::Acquire as _;

/// Scheduling-relevant view of an enabled jobset, as the evaluator's
/// scheduler sees it.
#[derive(Debug)]
pub(crate) struct JobsetSchedulingInfo {
    pub id: i32,
    pub project: String,
    pub name: String,
    pub lastcheckedtime: Option<db::Timestamp>,
    pub triggertime: Option<db::Timestamp>,
    pub checkinterval: i32,
    /// Raw `enabled` column: 1 = enabled, 2 = one-shot, 3 = one-at-a-time.
    pub enabled: i32,
}

pub(crate) trait JobsetQueries {
    /// All enabled jobsets of enabled projects.
    async fn get_schedulable_jobsets(&mut self) -> Result<Vec<JobsetSchedulingInfo>, sqlx::Error>;

    /// The most recent evaluation of a jobset, if any.
    async fn get_latest_eval_id(&mut self, jobset_id: i32) -> Result<Option<i32>, sqlx::Error>;

    /// Whether an evaluation still has unfinished builds.
    async fn eval_has_unfinished_builds(&mut self, eval_id: i32) -> Result<bool, sqlx::Error>;

    /// Record builds the evaluation needed in order to run at all —
    /// reading a derivation's output — as members of it, flagged so they are not
    /// mistaken for its jobs.
    ///
    /// Ignores builds already linked: an evaluation can reach the same
    /// derivation more than once, and the second time is not an error.
    async fn add_builds_for_evaluation(
        &mut self,
        eval_id: i32,
        build_ids: &[i32],
    ) -> Result<(), sqlx::Error>;

    /// Mark a jobset as currently evaluating.
    async fn set_jobset_start_time(
        &mut self,
        jobset_id: i32,
        start_time: db::Timestamp,
    ) -> Result<(), sqlx::Error>;

    /// Clear `startTime` on all jobsets, e.g. after an unclean evaluator
    /// shutdown left some marked as evaluating.
    async fn unlock_all_jobsets(&mut self) -> Result<(), sqlx::Error>;

    /// Record the outcome of an evaluation attempt: clear `triggerTime`
    /// and `startTime`, and record the error on failure.
    ///
    /// Runs in a transaction so that a partial failure cannot clear
    /// `triggerTime` but leave `startTime` set, which would make the
    /// jobset appear permanently running.
    async fn update_jobset_after_eval(
        &mut self,
        jobset_id: i32,
        error_msg: Option<&str>,
        now: db::Timestamp,
    ) -> Result<(), sqlx::Error>;
}

impl JobsetQueries for db::Connection {
    async fn get_schedulable_jobsets(&mut self) -> Result<Vec<JobsetSchedulingInfo>, sqlx::Error> {
        sqlx::query_as!(
            JobsetSchedulingInfo,
            r#"
            SELECT
              j.id,
              j.project,
              j.name,
              lastCheckedTime,
              triggerTime,
              checkInterval,
              j.enabled
            FROM jobsets j
            JOIN projects p ON j.project = p.name
            WHERE j.enabled != 0 AND p.enabled != 0"#
        )
        .fetch_all(self.raw())
        .await
    }

    async fn get_latest_eval_id(&mut self, jobset_id: i32) -> Result<Option<i32>, sqlx::Error> {
        Ok(sqlx::query!(
            "SELECT id FROM jobsetevals WHERE jobset_id = $1 ORDER BY id DESC LIMIT 1",
            jobset_id,
        )
        .fetch_optional(self.raw())
        .await?
        .map(|v| v.id))
    }

    async fn eval_has_unfinished_builds(&mut self, eval_id: i32) -> Result<bool, sqlx::Error> {
        Ok(sqlx::query!(
            "SELECT b.id FROM builds b \
             JOIN jobsetevalmembers m ON m.build = b.id \
             WHERE m.eval = $1 AND b.finished = 0 \
             LIMIT 1",
            eval_id,
        )
        .fetch_optional(self.raw())
        .await?
        .is_some())
    }

    async fn add_builds_for_evaluation(
        &mut self,
        eval_id: i32,
        build_ids: &[i32],
    ) -> Result<(), sqlx::Error> {
        sqlx::query!(
            "INSERT INTO jobsetevalmembers (eval, build, isNew, forEvaluation) \
             SELECT $1, unnest($2::integer[]), 1, 1 \
             ON CONFLICT (eval, build) DO NOTHING",
            eval_id,
            build_ids,
        )
        .execute(self.raw())
        .await?;
        Ok(())
    }

    async fn set_jobset_start_time(
        &mut self,
        jobset_id: i32,
        start_time: db::Timestamp,
    ) -> Result<(), sqlx::Error> {
        sqlx::query!(
            "UPDATE jobsets SET startTime = $1 WHERE id = $2",
            start_time,
            jobset_id,
        )
        .execute(self.raw())
        .await?;
        Ok(())
    }

    async fn unlock_all_jobsets(&mut self) -> Result<(), sqlx::Error> {
        sqlx::query!("UPDATE jobsets SET startTime = null")
            .execute(self.raw())
            .await?;
        Ok(())
    }

    async fn update_jobset_after_eval(
        &mut self,
        jobset_id: i32,
        error_msg: Option<&str>,
        now: db::Timestamp,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.raw().begin().await?;

        // Clear trigger time to prevent a stuck eval loop
        sqlx::query!(
            "UPDATE jobsets SET triggerTime = null \
             WHERE id = $1 AND startTime IS NOT NULL AND triggerTime <= startTime",
            jobset_id,
        )
        .execute(&mut *tx)
        .await?;

        sqlx::query!(
            "UPDATE jobsets SET startTime = null WHERE id = $1",
            jobset_id,
        )
        .execute(&mut *tx)
        .await?;

        if let Some(error_msg) = error_msg {
            sqlx::query!(
                "UPDATE jobsets SET errorMsg = $1, lastCheckedTime = $2, \
                 errorTime = $2, fetchErrorMsg = null WHERE id = $3",
                error_msg,
                now,
                jobset_id,
            )
            .execute(&mut *tx)
            .await?;
        }

        tx.commit().await?;
        Ok(())
    }
}

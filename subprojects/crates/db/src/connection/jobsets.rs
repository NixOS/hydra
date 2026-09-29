use super::Handle;
use crate::models::{BuildSteps, Jobset};

impl<C: std::ops::DerefMut<Target = sqlx::PgConnection>> Handle<C> {
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
}

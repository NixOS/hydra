use super::{Handle, Transaction};
use crate::models::BuildID;

impl<C: std::ops::DerefMut<Target = sqlx::PgConnection>> Handle<C> {
    #[tracing::instrument(skip(self), err)]
    async fn notify_any(&mut self, channel: &str, msg: &str) -> crate::Result<()> {
        sqlx::query!("SELECT pg_notify($1::text, $2::text)", channel, msg)
            .execute(&mut *self.conn)
            .await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub async fn notify_builds_added(&mut self) -> crate::Result<()> {
        self.notify_any("builds_added", "?").await
    }

    #[tracing::instrument(skip(self, build_id), err)]
    pub async fn notify_build_started(&mut self, build_id: BuildID) -> crate::Result<()> {
        self.notify_any("build_started", &build_id.to_string())
            .await
    }

    #[tracing::instrument(skip(self, build_id, step_nr, log_file,), err)]
    pub async fn notify_step_finished(
        &mut self,
        build_id: BuildID,
        step_nr: i32,
        log_file: &str,
    ) -> crate::Result<()> {
        self.notify_any(
            "step_finished",
            &format!("{build_id}\t{step_nr}\t{log_file}"),
        )
        .await
    }
}

impl Transaction<'_> {
    #[tracing::instrument(skip(self, build_id, dependent_ids,), err)]
    pub async fn notify_build_finished(
        &mut self,
        build_id: BuildID,
        dependent_ids: &[BuildID],
    ) -> crate::Result<()> {
        // Postgres limits NOTIFY payloads to slightly less than 8000 bytes.
        // A cached build can finish thousands of dependent builds at once,
        // so split the dependents over multiple notifications that each
        // repeat the finished build id as the first field.
        const MAX_PAYLOAD_LEN: usize = 7000;

        let head = build_id.to_string();
        let mut payload = head.clone();

        for dep in dependent_ids {
            let dep = dep.to_string();
            if payload.len() + 1 + dep.len() > MAX_PAYLOAD_LEN {
                self.notify_any("build_finished", &payload).await?;
                payload = head.clone();
            }
            payload.push('\t');
            payload.push_str(&dep);
        }

        self.notify_any("build_finished", &payload).await?;
        Ok(())
    }

    #[tracing::instrument(skip(self), err)]
    pub(super) async fn notify_step_started(
        &mut self,
        build_id: BuildID,
        step_nr: i32,
    ) -> crate::Result<()> {
        self.notify_any("step_started", &format!("{build_id}\t{step_nr}"))
            .await
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use crate::Connection;
    use crate::models::BuildID;

    /// Regression test: a dependent list too large for a single NOTIFY
    /// payload is delivered completely across multiple notifications.
    #[tokio::test]
    async fn notify_build_finished_chunks_large_dependent_lists() {
        let (_pg, pool) = test_utils::TestPg::new().await;

        let mut listener = sqlx::postgres::PgListener::connect_with(&pool)
            .await
            .unwrap();
        listener.listen("build_finished").await.unwrap();

        let dependent_ids: Vec<BuildID> = (1_000_000..1_005_000).collect();
        let mut conn = Connection::new(pool.acquire().await.unwrap());
        let mut tx = conn.begin_transaction().await.unwrap();
        tx.notify_build_finished(42, &dependent_ids).await.unwrap();
        tx.commit().await.unwrap();

        let mut received = std::collections::HashSet::new();
        while received.len() < dependent_ids.len() {
            let notification = listener.recv().await.unwrap();
            let payload = notification.payload();
            assert!(payload.len() <= 8000, "payload too long: {}", payload.len());
            let mut fields = payload.split('\t');
            assert_eq!(fields.next(), Some("42"));
            received.extend(fields.map(|f| f.parse::<BuildID>().unwrap()));
        }
        assert!(dependent_ids.iter().all(|id| received.contains(id)));
    }
}

use crate::Error;

/// Error that a serialization-failure retry can recognise.
pub trait RetryableError {
    /// True if this error was a rolled-back Postgres serialization failure or
    /// deadlock that is safe to retry from the top.
    fn is_retryable_serialization_failure(&self) -> bool;
}

impl RetryableError for Error {
    fn is_retryable_serialization_failure(&self) -> bool {
        // 40001 = serialization_failure, 40P01 = deadlock_detected. The server
        // rolled the transaction back, so retrying from the top is safe.
        matches!(self, Self::Sql(sqlx::Error::Database(db))
            if matches!(db.code().as_deref(), Some("40001" | "40P01")))
    }
}

const SERIALIZATION_RETRY_ATTEMPTS: u32 = 10;

/// Retry `f` when it fails with a Postgres serialization failure or deadlock.
///
/// `f` must acquire its own connection and open its own transaction so that a
/// retry starts from a clean state.
pub async fn retry_serialization_failures<F, Fut, T, E>(what: &str, mut f: F) -> Result<T, E>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<T, E>>,
    E: RetryableError + std::fmt::Display,
{
    let mut attempt = 1;
    loop {
        match f().await {
            Err(e)
                if e.is_retryable_serialization_failure()
                    && attempt < SERIALIZATION_RETRY_ATTEMPTS =>
            {
                tracing::warn!(
                    "{what}: serialization failure, retrying ({attempt}/{SERIALIZATION_RETRY_ATTEMPTS}): {e}"
                );
                tokio::time::sleep(std::time::Duration::from_millis(u64::from(attempt) * 50)).await;
                attempt += 1;
            }
            other => return other,
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::RetryableError as _;
    use crate::Connection;

    /// A real Postgres deadlock (40P01) is classified as retryable.
    #[tokio::test]
    async fn deadlock_is_retryable_serialization_failure() {
        let (_pg, pool) = test_utils::TestPg::new().await;

        // Any two rows will do; users are the simplest table to seed.
        let mut setup = Connection::new(pool.acquire().await.unwrap());
        sqlx::query!(
            "INSERT INTO Users (userName, fullName, emailAddress, password)
             VALUES ('a', '', 'a@example.org', ''), ('b', '', 'b@example.org', '')"
        )
        .execute(setup.raw())
        .await
        .unwrap();

        let mut conn_a = Connection::new(pool.acquire().await.unwrap());
        let mut conn_b = Connection::new(pool.acquire().await.unwrap());

        let mut tx_a = conn_a.begin_transaction().await.unwrap();
        sqlx::query!("UPDATE Users SET fullName = 'first' WHERE userName = 'a'")
            .execute(tx_a.raw())
            .await
            .unwrap();

        let mut tx_b = conn_b.begin_transaction().await.unwrap();
        sqlx::query!("UPDATE Users SET fullName = 'first' WHERE userName = 'b'")
            .execute(tx_b.raw())
            .await
            .unwrap();

        // Each transaction now reaches for the row the other holds, closing the
        // cycle; Postgres aborts one of them with a deadlock error.
        let (res_a, res_b) = tokio::join!(
            sqlx::query!("UPDATE Users SET fullName = 'second' WHERE userName = 'b'")
                .execute(tx_a.raw()),
            sqlx::query!("UPDATE Users SET fullName = 'second' WHERE userName = 'a'")
                .execute(tx_b.raw()),
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

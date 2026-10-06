/// Data in the database couldn't be parsed into domain types.
#[derive(Debug, thiserror::Error)]
pub enum DataError {
    #[error(transparent)]
    StorePath(#[from] harmonia_store_path::ParseStorePathError),

    #[error(transparent)]
    StorePathName(#[from] harmonia_store_path::StorePathNameError),

    #[error(transparent)]
    IntConversion(#[from] std::num::TryFromIntError),

    #[error("build product #{productnr} for build {build_id} has no path")]
    BuildProductMissingPath {
        build_id: crate::models::BuildID,
        productnr: i32,
    },

    /// A row's storeDir column disagrees with the store dir this queue
    /// runner is configured for. The DB may legitimately hold rows from
    /// another store, but this deployment cannot act on them.
    #[error("row's store dir `{found}` does not match the configured store dir `{expected}`")]
    StoreDirMismatch { expected: String, found: String },
}

/// Errors from the db crate.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    /// Database connection or query error — infrastructure failure.
    #[error(transparent)]
    Sql(#[from] sqlx::Error),

    /// Data in the database couldn't be parsed into domain types.
    #[error("invalid data from database: {0}")]
    Data(#[from] DataError),
}

impl From<harmonia_store_path::ParseStorePathError> for Error {
    fn from(e: harmonia_store_path::ParseStorePathError) -> Self {
        Self::Data(e.into())
    }
}

impl From<harmonia_store_path::StorePathNameError> for Error {
    fn from(e: harmonia_store_path::StorePathNameError) -> Self {
        Self::Data(e.into())
    }
}

impl From<std::num::TryFromIntError> for Error {
    fn from(e: std::num::TryFromIntError) -> Self {
        Self::Data(e.into())
    }
}

pub type Result<T> = std::result::Result<T, Error>;

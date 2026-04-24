use harmonia_store_core::store_path::{ParseStorePathError, StoreDir, StorePath};

/// A store path with an optional relative sub-path.
///
/// Represents paths like `/nix/store/<hash>-<name>/share/doc/nix/manual`,
/// split into the base `StorePath` (`<hash>-<name>`) and the relative
/// suffix (`share/doc/nix/manual`).
#[derive(Debug, Clone)]
pub struct RelativeStorePath {
    pub base_path: StorePath,
    pub relative_path: Box<str>,
}

impl RelativeStorePath {
    /// Parse a full filesystem path under a store directory into a
    /// `StorePath` and a relative suffix.
    ///
    /// For `/nix/store/<hash>-<name>/foo/bar` returns base=`<hash>-<name>`,
    /// relative=`"foo/bar"`.
    /// For `/nix/store/<hash>-<name>` returns base=`<hash>-<name>`,
    /// relative=`""`.
    pub fn from_path(store_dir: &StoreDir, path: &str) -> Result<Self, ParseStorePathError> {
        let stripped = store_dir
            .strip_prefix(path)
            .map_err(|e| ParseStorePathError::new(path, e))?;
        let (base_str, relative) = stripped.split_once('/').unwrap_or((stripped, ""));
        Ok(Self {
            base_path: StorePath::from_base_path(base_str)?,
            relative_path: relative.into(),
        })
    }

    /// Render back into a full filesystem path.
    pub fn print(&self, store_dir: &StoreDir) -> String {
        if self.relative_path.is_empty() {
            store_dir.display(&self.base_path).to_string()
        } else {
            format!(
                "{}/{}",
                store_dir.display(&self.base_path),
                self.relative_path
            )
        }
    }
}

impl From<RelativeStorePath> for (StorePath, Box<str>) {
    fn from(r: RelativeStorePath) -> Self {
        (r.base_path, r.relative_path)
    }
}

impl From<(StorePath, Box<str>)> for RelativeStorePath {
    fn from((base_path, relative_path): (StorePath, Box<str>)) -> Self {
        Self {
            base_path,
            relative_path,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_store_dir() -> StoreDir {
        StoreDir::new("/nix/store").unwrap()
    }

    #[test]
    fn splits_product_subpath() {
        let dir = test_store_dir();
        let rel = RelativeStorePath::from_path(
            &dir,
            "/nix/store/bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4/share/doc/nix/manual",
        )
        .expect("subpath product must parse");
        assert_eq!(
            rel.base_path.to_string(),
            "bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4"
        );
        assert_eq!(&*rel.relative_path, "share/doc/nix/manual");
    }

    #[test]
    fn accepts_bare_store_path() {
        let dir = test_store_dir();
        let rel = RelativeStorePath::from_path(
            &dir,
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0",
        )
        .expect("bare store path must parse");
        assert_eq!(
            rel.base_path.to_string(),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0"
        );
        assert!(rel.relative_path.is_empty());
    }

    #[test]
    fn roundtrips() {
        let dir = test_store_dir();
        for original in [
            "/nix/store/bwqqp42xqn37z31dapi7jrhy8iwc2zsx-nix-manual-2.31.4/share/doc/nix/manual",
            "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-example-1.0",
        ] {
            let rel = RelativeStorePath::from_path(&dir, original)
                .unwrap_or_else(|e| panic!("parse {original}: {e}"));
            assert_eq!(rel.print(&dir), original);
        }
    }
}

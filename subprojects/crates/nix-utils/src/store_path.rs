#[allow(unreachable_pub)]
pub use harmonia_store_core::store_path::{
    ParseStorePathError,
    StoreDir,
    StoreDirDisplay,
    StorePath,
    StorePathHash,
    StorePathName,
};

/// Parse a store path from a string that may or may not have the store dir
/// prefix. Handles paths inside store outputs (e.g.
/// `/nix/store/hash-name/subdir/file`).
#[must_use]
pub fn parse_store_path(s: &str) -> StorePath {
    let after_store = s.find("/store/").map_or(s, |i| &s[i + 7..]);
    let base = after_store.split('/').next().unwrap_or(after_store);
    base.parse()
        .unwrap_or_else(|e| panic!("invalid store path '{s}': {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_base_name() {
        let sp = parse_store_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package-name");
        assert_eq!(
            sp.to_string(),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package-name"
        );
    }

    #[test]
    fn test_parse_with_store_prefix() {
        let sp = parse_store_path("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package-name");
        assert_eq!(
            sp.to_string(),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package-name"
        );
    }

    #[test]
    fn test_parse_with_subpath() {
        let sp =
            parse_store_path("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package-name/bin/hello");
        assert_eq!(
            sp.to_string(),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package-name"
        );
    }

    #[test]
    fn test_is_drv() {
        let drv = parse_store_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package.drv");
        let regular = parse_store_path("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-package");
        assert!(drv.is_derivation());
        assert!(!regular.is_derivation());
    }
}

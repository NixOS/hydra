pub const HASH_LEN: usize = 32;

#[derive(Debug, Clone, Hash, PartialEq, Eq, PartialOrd, Ord)]
pub struct StorePath {
    base_name: String,
}

impl StorePath {
    #[must_use]
    pub fn new(p: &str) -> Self {
        p.strip_prefix("/nix/store/").map_or_else(
            || {
                debug_assert!(p.len() > HASH_LEN + 1);
                Self {
                    base_name: p.to_string(),
                }
            },
            |postfix| {
                debug_assert!(postfix.len() > HASH_LEN + 1);
                Self {
                    base_name: postfix.to_string(),
                }
            },
        )
    }

    #[must_use]
    pub fn into_base_name(self) -> String {
        self.base_name
    }

    #[must_use]
    pub fn base_name(&self) -> &str {
        &self.base_name
    }

    #[must_use]
    pub fn name(&self) -> &str {
        &self.base_name[HASH_LEN + 1..]
    }

    #[must_use]
    pub fn hash_part(&self) -> &str {
        &self.base_name[..HASH_LEN]
    }

    #[must_use]
    pub fn is_drv(&self) -> bool {
        std::path::Path::new(&self.base_name)
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("drv"))
    }
}

impl serde::Serialize for StorePath {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.base_name())
    }
}

impl std::fmt::Display for StorePath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> Result<(), std::fmt::Error> {
        write!(f, "{}", self.base_name)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_store_path_creation() {
        let path_str = "abc123def45678901234567890123456-package-name";
        let store_path = StorePath::new(path_str);

        assert_eq!(store_path.base_name(), path_str);
        assert_eq!(store_path.name(), "package-name");
        assert_eq!(store_path.hash_part(), "abc123def45678901234567890123456");
    }

    #[test]
    fn test_store_path_with_prefix() {
        let store_path = StorePath::new("abc123def45678901234567890123456-package-name");

        assert_eq!(
            store_path.base_name(),
            "abc123def45678901234567890123456-package-name"
        );
        assert_eq!(store_path.name(), "package-name");
        assert_eq!(store_path.hash_part(), "abc123def45678901234567890123456");
    }

    #[test]
    fn test_store_path_is_drv() {
        let drv_path = StorePath::new("abc123def45678901234567890123456-package.drv");
        let regular_path = StorePath::new("abc123def45678901234567890123456-package");

        assert!(drv_path.is_drv());
        assert!(!regular_path.is_drv());
    }

    #[test]
    fn test_store_path_display() {
        let path_str = "abc123def45678901234567890123456-package-name";
        let store_path = StorePath::new(path_str);

        assert_eq!(format!("{store_path}"), path_str);
    }

    // #[test]
    // TODO: we cant write tests accessing ffi: https://github.com/dtolnay/cxx/issues/1318
    // fn test_local_store_print_store_path() {
    //     let store = crate::LocalStore::init();
    //     let path_str = "abc123def45678901234567890123456-package-name";
    //     let store_path = StorePath::new(path_str);
    //
    //     let printed_path = store.print_store_path(&store_path);
    //     let expected_prefix = crate::get_store_dir();
    //     let expected_path = format!("{}/{}", expected_prefix, path_str);
    //
    //     assert_eq!(printed_path, expected_path);
    // }

    #[test]
    fn test_store_path_into_base_name() {
        let path_str = "abc123def45678901234567890123456-package-name";
        let store_path = StorePath::new(path_str);

        let base_name = store_path.into_base_name();
        assert_eq!(base_name, path_str);
    }
}

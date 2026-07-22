//! Debug info processing functionality for binary cache.
//!
//! This module handles the extraction and processing of debug information
//! from NIX store paths that contain debug symbols in the standard
//! `lib/debug/.build-id` directory structure.

use crate::CacheError;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub(crate) struct DebugInfoLink {
    pub(crate) archive: String,
    pub(crate) member: String,
}

/// Processes debug info for a given store path using a custom full path.
/// This is useful for testing with custom store prefixes.
pub(crate) async fn process_debug_info<C>(
    nar_url: &str,
    real_store_dir: &std::path::Path,
    store_path: &harmonia_store_path::StorePath,
    client: C,
) -> Result<(), CacheError>
where
    C: DebugInfoClient + Clone + Send + Sync + 'static,
{
    use futures::stream::StreamExt as _;

    let full_path = real_store_dir.join(store_path.to_string());
    let build_id_path = full_path.join("lib/debug/.build-id");

    if !build_id_path.exists() {
        tracing::debug!("No lib/debug/.build-id directory found in {}", store_path);
        return Ok(());
    }

    let debug_files = find_debug_files(&build_id_path).await?;
    let mut stream = tokio_stream::iter(debug_files)
        .map(|(build_id, debug_path)| {
            let client = client.clone();
            async move {
                client
                    .create_debug_info_link(nar_url, build_id, debug_path)
                    .await
            }
        })
        .buffered(25);
    while let Some(result) = tokio_stream::StreamExt::next(&mut stream).await {
        result?;
    }
    Ok(())
}

pub async fn get_debug_info_build_ids(
    real_store_dir: &std::path::Path,
    store_path: &harmonia_store_path::StorePath,
) -> Result<Vec<String>, CacheError> {
    let full_path = real_store_dir.join(store_path.to_string());
    let build_id_path = full_path.join("lib/debug/.build-id");

    if !build_id_path.exists() {
        tracing::debug!("No lib/debug/.build-id directory found in {}", store_path);
        return Ok(vec![]);
    }

    Ok(find_debug_files(&build_id_path)
        .await?
        .into_iter()
        .map(|(id, _)| id)
        .collect())
}

/// Finds debug files by scanning the build-id directory structure.
#[allow(clippy::case_sensitive_file_extension_comparisons)]
async fn find_debug_files(
    build_id_path: &std::path::Path,
) -> Result<Vec<(String, String)>, CacheError> {
    let mut debug_files = Vec::new();

    let mut entries = fs_err::tokio::read_dir(build_id_path)
        .await
        .map_err(CacheError::Io)?;

    // Debuginfo is always stored in a directory called {aa}/{bb...}.debug,
    // where {aa} and {bb...} are hexadecimal.
    // gdb and elfutils assume that the hexadecimal and "debug" are lowercase.
    // The concatenation of {aa} and {bb...} represent the ID in the ELF's
    // `.note.gnu.build-id` section, and must be a whole number of bytes.
    // GNU ld, gold, mold, and lld are capable of using a user-specified ID or
    // an automatically-generated ID of 8, 16, or 20 bytes.
    // elfutils assumes all build IDs are 3–64 bytes (inclusive),

    // The elfutils and gdb assumptions are reasonable, so we can limit ourselves
    // to 3–64 bytes worth of lowercase hexadecimal followed by a lowercase ".debug"

    while let Some(entry) = entries.next_entry().await.map_err(CacheError::Io)? {
        let Ok(outer_name) = entry.file_name().into_string() else {
            tracing::warn!(
                "Skipping build-id entry with a non-UTF-8 name: {}",
                entry.path().display()
            );
            continue;
        };

        // Check if it's a 2-character hex directory
        if outer_name.len() != 2
            || !outer_name
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
            || !entry.file_type().await.map_err(CacheError::Io)?.is_dir()
        {
            tracing::debug!(
                "Skipping unexpected entry in .build-id: {}",
                entry.path().display()
            );
            continue;
        }

        let subdir_path = build_id_path.join(&outer_name);
        let mut subdir_entries = fs_err::tokio::read_dir(&subdir_path)
            .await
            .map_err(CacheError::Io)?;

        while let Some(sub_entry) = subdir_entries.next_entry().await.map_err(CacheError::Io)? {
            let sub_path = sub_entry.path();
            if sub_path.extension() != Some("debug".as_ref()) {
                tracing::debug!("Skipping non-debug file: {}", sub_path.display());
                continue;
            }

            // `file_stem` only fails to produce a `&str` for a non-UTF-8 name,
            // which a real build ID should never have.
            let Some(sub_name) = sub_path.file_stem().and_then(|name| name.to_str()) else {
                tracing::warn!(
                    "Skipping debug file with a non-UTF-8 name: {}",
                    sub_path.display()
                );
                continue;
            };

            // The build ID format is `{outer_name}{sub_name}` in hex, and takes two chars per byte.
            let build_id_hex_chars = outer_name.len() + sub_name.len();
            let build_id_bytes = build_id_hex_chars / 2;
            if !(3..=64).contains(&build_id_bytes) {
                tracing::debug!(
                    "Skipping debug file with a build ID of {build_id_bytes} bytes, expected 3-64: {}",
                    sub_path.display()
                );
                continue;
            }

            if !sub_name
                .chars()
                .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
            {
                tracing::debug!(
                    "Skipping debug file with a non-hexadecimal build ID: {}",
                    sub_path.display()
                );
                continue;
            }

            if !sub_entry
                .file_type()
                .await
                .map_err(CacheError::Io)?
                .is_file()
            {
                tracing::debug!("Skipping non-file debug entry: {}", sub_path.display());
                continue;
            }

            let build_id = format!("{outer_name}{sub_name}");
            let debug_path = format!("lib/debug/.build-id/{outer_name}/{sub_name}.debug");
            debug_files.push((build_id, debug_path));
        }
    }

    Ok(debug_files)
}

pub(crate) trait DebugInfoClient {
    async fn create_debug_info_link(
        &self,
        nar_url: &str,
        build_id: String,
        debug_path: String,
    ) -> Result<(), CacheError>;
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[derive(Debug, Clone)]
    struct MockClient {
        created_links: std::sync::Arc<std::sync::Mutex<Vec<DebugInfoLink>>>,
    }

    impl MockClient {
        fn new() -> Self {
            Self {
                created_links: std::sync::Arc::new(std::sync::Mutex::new(Vec::new())),
            }
        }

        fn get_created_links(&self) -> Vec<DebugInfoLink> {
            self.created_links.lock().unwrap().clone()
        }
    }

    impl DebugInfoClient for MockClient {
        async fn create_debug_info_link(
            &self,
            nar_url: &str,
            _build_id: String,
            debug_path: String,
        ) -> Result<(), CacheError> {
            let link = DebugInfoLink {
                archive: format!("../{nar_url}"),
                member: debug_path,
            };

            self.created_links.lock().unwrap().push(link);
            Ok(())
        }
    }

    #[tokio::test]
    async fn test_find_debug_files() {
        let temp_dir = tempfile::tempdir().unwrap().keep();
        let build_id_dir = temp_dir.join("test_build_id");

        fs_err::tokio::create_dir_all(&build_id_dir).await.unwrap();

        let ab_dir = build_id_dir.join("ab");
        fs_err::tokio::create_dir(&ab_dir).await.unwrap();
        fs_err::tokio::write(
            &ab_dir.join("cdef1234567890123456789012345678901234.debug"),
            "test debug content",
        )
        .await
        .unwrap();

        let cd_dir = build_id_dir.join("cd");
        fs_err::tokio::create_dir(&cd_dir).await.unwrap();
        fs_err::tokio::write(
            &cd_dir.join("ef567890123456789012345678901234567890.debug"),
            "test debug content 2",
        )
        .await
        .unwrap();

        let mut debug_files = find_debug_files(&build_id_dir).await.unwrap();
        debug_files.sort_by(|(a, _), (b, _)| a.cmp(b));

        assert_eq!(debug_files.len(), 2);
        assert_eq!(
            debug_files[0],
            (
                "abcdef1234567890123456789012345678901234".to_string(),
                "lib/debug/.build-id/ab/cdef1234567890123456789012345678901234.debug".to_string()
            )
        );
        assert_eq!(
            debug_files[1],
            (
                "cdef567890123456789012345678901234567890".to_string(),
                "lib/debug/.build-id/cd/ef567890123456789012345678901234567890.debug".to_string()
            )
        );

        fs_err::tokio::remove_dir_all(&build_id_dir).await.unwrap();
    }

    #[tokio::test]
    async fn test_process_debug_info_integration() {
        let mock_client = MockClient::new();

        let temp_dir = tempfile::tempdir().unwrap().keep();
        let store_prefix = temp_dir.join("nix/store");
        let store_path_str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-debug-output";
        let store_dir = harmonia_store_path::StoreDir::new(store_prefix.as_path()).unwrap();
        let store_path = harmonia_store_path::StorePath::from_base_path(store_path_str).unwrap();
        let full_path = store_prefix.join(store_path_str);

        fs_err::tokio::create_dir_all(&full_path).await.unwrap();
        let build_id_dir = full_path.join("lib/debug/.build-id");
        fs_err::tokio::create_dir_all(&build_id_dir).await.unwrap();

        let ab_dir = build_id_dir.join("ab");
        fs_err::tokio::create_dir(&ab_dir).await.unwrap();
        let debug_file = ab_dir.join("cdef1234567890123456789012345678901234.debug");
        fs_err::tokio::write(&debug_file, "test debug content")
            .await
            .unwrap();

        process_debug_info(
            "test.nar",
            store_dir.as_ref(),
            &store_path,
            mock_client.clone(),
        )
        .await
        .unwrap();

        let created_links = mock_client.get_created_links();
        assert_eq!(created_links.len(), 1);
        assert_eq!(created_links[0].archive, "../test.nar");
        assert_eq!(
            created_links[0].member,
            "lib/debug/.build-id/ab/cdef1234567890123456789012345678901234.debug"
        );

        fs_err::tokio::remove_dir_all(&full_path).await.unwrap();
    }

    #[tokio::test]
    async fn test_find_debug_files_empty_directory() {
        let temp_dir = tempfile::tempdir().unwrap().keep();
        let build_id_dir = temp_dir.join("empty_build_id");

        fs_err::tokio::create_dir_all(&build_id_dir).await.unwrap();

        let debug_files = find_debug_files(&build_id_dir).await.unwrap();
        assert_eq!(debug_files.len(), 0);

        fs_err::tokio::remove_dir_all(&build_id_dir).await.unwrap();
    }

    #[tokio::test]
    async fn test_find_debug_files_invalid_structure() {
        let temp_dir = tempfile::tempdir().unwrap().keep();
        let build_id_dir = temp_dir.join("invalid_build_id");

        fs_err::tokio::create_dir_all(&build_id_dir).await.unwrap();

        fs_err::tokio::create_dir(&build_id_dir.join("invalid"))
            .await
            .unwrap();
        fs_err::tokio::create_dir(&build_id_dir.join("xyz"))
            .await
            .unwrap();
        fs_err::tokio::create_dir(&build_id_dir.join("123"))
            .await
            .unwrap();

        let valid_dir = build_id_dir.join("ab");
        fs_err::tokio::create_dir(&valid_dir).await.unwrap();

        fs_err::tokio::write(&valid_dir.join("invalid.txt"), "content")
            .await
            .unwrap();
        fs_err::tokio::write(
            &valid_dir.join("cdef1234567890123456789012345678901234.txt"),
            "content",
        )
        .await
        .unwrap();
        fs_err::tokio::write(
            &valid_dir.join("xyz1234567890123456789012345678901234.debug"),
            "content",
        )
        .await
        .unwrap();

        let debug_files = find_debug_files(&build_id_dir).await.unwrap();
        assert_eq!(debug_files.len(), 0);

        fs_err::tokio::remove_dir_all(&build_id_dir).await.unwrap();
    }

    #[tokio::test]
    async fn test_find_debug_files_mixed_valid_invalid() {
        let temp_dir = tempfile::tempdir().unwrap().keep();
        let build_id_dir = temp_dir.join("mixed_build_id");

        fs_err::tokio::create_dir_all(&build_id_dir).await.unwrap();

        let ab_dir = build_id_dir.join("ab");
        fs_err::tokio::create_dir(&ab_dir).await.unwrap();
        fs_err::tokio::write(
            &ab_dir.join("cdef123456789012345678901234567890123456.debug"),
            "valid debug content",
        )
        .await
        .unwrap();

        fs_err::tokio::create_dir(&build_id_dir.join("invalid"))
            .await
            .unwrap();
        fs_err::tokio::write(
            &build_id_dir.join("invalid").join("somefile.debug"),
            "content",
        )
        .await
        .unwrap();

        let cd_dir = build_id_dir.join("cd");
        fs_err::tokio::create_dir(&cd_dir).await.unwrap();
        fs_err::tokio::write(
            &cd_dir.join("ef567890123456789012345678901234567890.debug"),
            "another valid debug content",
        )
        .await
        .unwrap();
        fs_err::tokio::write(&cd_dir.join("invalid.txt"), "invalid content")
            .await
            .unwrap();

        let debug_files = find_debug_files(&build_id_dir).await.unwrap();
        assert_eq!(debug_files.len(), 2);

        let build_ids: Vec<String> = debug_files.iter().map(|(id, _)| id.clone()).collect();
        assert!(build_ids.contains(&"abcdef123456789012345678901234567890123456".to_string()));
        assert!(build_ids.contains(&"cdef567890123456789012345678901234567890".to_string()));

        fs_err::tokio::remove_dir_all(&build_id_dir).await.unwrap();
    }

    #[tokio::test]
    async fn test_process_debug_info_no_build_id_dir() {
        let mock_client = MockClient::new();

        let temp_dir = tempfile::tempdir().unwrap().keep();
        let store_prefix = temp_dir.join("nix/store");
        let store_path_str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-no-debug";
        let store_dir = harmonia_store_path::StoreDir::new(store_prefix.as_path()).unwrap();
        let store_path = harmonia_store_path::StorePath::from_base_path(store_path_str).unwrap();
        let full_path = temp_dir.join("nix/store").join(store_path_str);

        fs_err::tokio::create_dir_all(&full_path).await.unwrap();

        process_debug_info(
            "test.nar",
            store_dir.as_ref(),
            &store_path,
            mock_client.clone(),
        )
        .await
        .unwrap();

        let created_links = mock_client.get_created_links();
        assert_eq!(created_links.len(), 0);

        fs_err::tokio::remove_dir_all(&full_path).await.unwrap();
    }

    #[tokio::test]
    async fn test_process_debug_info_empty_build_id_dir() {
        let mock_client = MockClient::new();

        let temp_dir = tempfile::tempdir().unwrap().keep();
        let store_prefix = temp_dir.join("nix/store");
        let store_path_str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-empty-debug";
        let store_dir = harmonia_store_path::StoreDir::new(store_prefix.as_path()).unwrap();
        let store_path = harmonia_store_path::StorePath::from_base_path(store_path_str).unwrap();
        let full_path = temp_dir.join("nix/store").join(store_path_str);

        fs_err::tokio::create_dir_all(&full_path).await.unwrap();
        let build_id_dir = full_path.join("lib/debug/.build-id");
        fs_err::tokio::create_dir_all(&build_id_dir).await.unwrap();

        process_debug_info(
            "test.nar",
            store_dir.as_ref(),
            &store_path,
            mock_client.clone(),
        )
        .await
        .unwrap();

        let created_links = mock_client.get_created_links();
        assert_eq!(created_links.len(), 0);

        fs_err::tokio::remove_dir_all(&full_path).await.unwrap();
    }

    #[tokio::test]
    async fn test_process_debug_info_multiple_files() {
        let mock_client = MockClient::new();

        let temp_dir = tempfile::tempdir().unwrap().keep();
        let store_prefix = temp_dir.join("nix/store");
        let store_path_str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-multi-debug";
        let store_dir = harmonia_store_path::StoreDir::new(store_prefix.as_path()).unwrap();
        let store_path = harmonia_store_path::StorePath::from_base_path(store_path_str).unwrap();
        let full_path = temp_dir.join("nix/store").join(store_path_str);

        fs_err::tokio::create_dir_all(&full_path).await.unwrap();
        let build_id_dir = full_path.join("lib/debug/.build-id");
        fs_err::tokio::create_dir_all(&build_id_dir).await.unwrap();

        let subdirs = [
            ("ab", "cdef1234567890123456789012345678901234"),
            ("cd", "ef567890123456789012345678901234567890"),
            ("12", "34567890123456789012345678901234567890"),
        ];

        for (subdir, filename) in &subdirs {
            let dir = build_id_dir.join(subdir);
            fs_err::tokio::create_dir(&dir).await.unwrap();
            fs_err::tokio::write(&dir.join(format!("{filename}.debug")), "debug content")
                .await
                .unwrap();
        }

        process_debug_info(
            "multi.nar",
            store_dir.as_ref(),
            &store_path,
            mock_client.clone(),
        )
        .await
        .unwrap();

        let created_links = mock_client.get_created_links();
        assert_eq!(created_links.len(), 3);

        for link in &created_links {
            assert_eq!(link.archive, "../multi.nar");
        }

        let members: Vec<String> = created_links.iter().map(|l| l.member.clone()).collect();
        assert!(members.contains(
            &"lib/debug/.build-id/ab/cdef1234567890123456789012345678901234.debug".to_string()
        ));
        assert!(members.contains(
            &"lib/debug/.build-id/cd/ef567890123456789012345678901234567890.debug".to_string()
        ));
        assert!(members.contains(
            &"lib/debug/.build-id/12/34567890123456789012345678901234567890.debug".to_string()
        ));

        fs_err::tokio::remove_dir_all(&full_path).await.unwrap();
    }

    #[tokio::test]
    async fn test_debug_info_link_serialization() {
        let link = DebugInfoLink {
            archive: "../test.nar".to_string(),
            member: "lib/debug/.build-id/ab/cdef1234567890123456789012345678901234.debug"
                .to_string(),
        };

        let json = serde_json::to_string(&link).unwrap();
        let expected = r#"{"archive":"../test.nar","member":"lib/debug/.build-id/ab/cdef1234567890123456789012345678901234.debug"}"#;
        assert_eq!(json, expected);

        let deserialized: DebugInfoLink = serde_json::from_str(&json).unwrap();
        assert_eq!(deserialized.archive, link.archive);
        assert_eq!(deserialized.member, link.member);
    }
}

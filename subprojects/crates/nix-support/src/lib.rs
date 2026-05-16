//! Parser for `nix-support/` files (build products, metrics, release name).
//!
//! This crate reads the `nix-support/hydra-build-products`,
//! `nix-support/hydra-metrics`, `nix-support/hydra-release-name`, and
//! `nix-support/failed` files from store path outputs, producing typed
//! [`NixSupport`] data.
//!
//! Paths are represented as [`StorePath`] or [`RelativeStorePath`] rather
//! than raw strings, so callers resolve to the real filesystem only at
//! the IO boundary.

#![forbid(unsafe_code)]
#![deny(
    clippy::all,
    clippy::pedantic,
    clippy::expect_used,
    clippy::unwrap_used,
    future_incompatible,
    missing_debug_implementations,
    nonstandard_style,
    unreachable_pub,
    missing_copy_implementations,
    unused_qualifications
)]
#![allow(clippy::missing_errors_doc)]

use std::{collections::BTreeMap, os::unix::fs::MetadataExt as _, sync::LazyLock};

use sha2::{Digest as _, Sha256};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, BufReader};

use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::StorePath;
use store_path_utils::RelativeStorePath;

#[allow(clippy::expect_used)]
static VALIDATE_METRICS_NAME: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new("[a-zA-Z0-9._-]+").expect("Failed to compile regex"));
#[allow(clippy::expect_used)]
static VALIDATE_METRICS_UNIT: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new("[a-zA-Z0-9._%-]+").expect("Failed to compile regex"));
#[allow(clippy::expect_used)]
static VALIDATE_RELEASE_NAME: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new("[a-zA-Z0-9.@:_-]+").expect("Failed to compile regex"));
#[allow(clippy::expect_used)]
static VALIDATE_PRODUCT_NAME: LazyLock<regex::Regex> =
    LazyLock::new(|| regex::Regex::new("[a-zA-Z0-9.@:_ -]*").expect("Failed to compile regex"));
#[allow(clippy::expect_used)]
static BUILD_PRODUCT_PARSER: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(
        r#"([a-zA-Z0-9_-]+)\s+([a-zA-Z0-9_-]+)\s+(\"[^\"]+\"|[^\"\s<>]+)(\s+([^\"\s<>]+))?"#,
    )
    .expect("Failed to compile regex")
});

#[derive(Debug, Clone, PartialEq)]
pub struct BuildProduct {
    pub path: RelativeStorePath,
    pub default_path: String,

    pub r#type: String,
    pub subtype: String,
    pub name: String,

    pub is_regular: bool,

    pub sha256hash: Option<harmonia_utils_hash::Sha256>,
    pub file_size: Option<u64>,
}

pub type BuildMetricName = String;

#[derive(Debug, Clone, PartialEq)]
pub struct BuildMetric {
    pub unit: Option<String>,
    pub value: f64,
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct NixSupport {
    pub failed: bool,
    pub hydra_release_name: Option<String>,
    pub metrics: BTreeMap<BuildMetricName, BuildMetric>,
    pub products: Vec<BuildProduct>,
}

/// File metadata needed for build products.
#[derive(Debug, Clone, Copy)]
pub struct FileMetadata {
    pub is_regular: bool,
    pub size: u64,
}

/// Abstraction over filesystem operations needed for parsing build products.
///
/// The default implementation ([`FilesystemOperations`]) reads from the real
/// filesystem. Tests can provide a mock implementation.
pub trait FsOperations {
    fn get_file_info(&self, path: &RelativeStorePath)
    -> impl Future<Output = Option<FileMetadata>>;

    fn hash_file(
        &self,
        path: &RelativeStorePath,
    ) -> impl Future<Output = Option<harmonia_utils_hash::Sha256>>;
}

/// Real filesystem implementation of [`FsOperations`].
#[derive(Debug, Clone)]
pub struct FilesystemOperations {
    pub real_store_dir: std::path::PathBuf,
}

impl FilesystemOperations {
    fn resolve(&self, path: &RelativeStorePath) -> std::path::PathBuf {
        let mut p = self.real_store_dir.join(path.base_path.to_string());
        if !path.relative_path.is_empty() {
            p = p.join(&*path.relative_path);
        }
        p
    }
}

impl FsOperations for FilesystemOperations {
    async fn get_file_info(&self, path: &RelativeStorePath) -> Option<FileMetadata> {
        let real = self.resolve(path);
        let m = fs_err::tokio::metadata(&real).await.ok()?;
        Some(FileMetadata {
            is_regular: m.is_file(),
            size: m.size(),
        })
    }

    async fn hash_file(&self, path: &RelativeStorePath) -> Option<harmonia_utils_hash::Sha256> {
        let real = self.resolve(path);
        let file = fs_err::tokio::File::open(&real).await.ok()?;
        let mut reader = BufReader::new(file);
        let mut hasher = Sha256::new();
        let mut buf = [0u8; 16 * 1024];
        loop {
            let n = reader.read(&mut buf).await.ok()?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }
        let digest = hasher.finalize();
        harmonia_utils_hash::Sha256::from_slice(&digest).ok()
    }
}

fn parse_release_name(content: &str) -> Option<String> {
    let content = content.trim();
    if !content.is_empty() && VALIDATE_RELEASE_NAME.is_match(content) {
        Some(content.to_owned())
    } else {
        None
    }
}

fn parse_metric(line: &str) -> Option<(BuildMetricName, BuildMetric)> {
    let fields: Vec<&str> = line.split_whitespace().collect();
    if fields.len() < 2 || !VALIDATE_METRICS_NAME.is_match(fields[0]) {
        return None;
    }

    let value: f64 = fields[1].parse().ok()?;

    let unit = if fields.len() >= 3 && VALIDATE_METRICS_UNIT.is_match(fields[2]) {
        Some(fields[2].to_owned())
    } else {
        None
    };

    Some((fields[0].to_owned(), BuildMetric { value, unit }))
}

/// Resolve a store path to a filesystem path.
fn real_path(store_dir: &std::path::Path, path: &StorePath) -> std::path::PathBuf {
    store_dir.join(path.to_string())
}

async fn parse_build_product<F: FsOperations>(
    store_dir: &harmonia_store_path::StoreDir,
    fs: &F,
    line: &str,
) -> Option<BuildProduct> {
    let captures = BUILD_PRODUCT_PARSER.captures(line)?;

    let s = captures[3].to_string();
    let path_str = if s.starts_with('"') && s.ends_with('"') {
        s[1..s.len() - 1].to_string()
    } else {
        s
    };

    if path_str.is_empty() || !path_str.starts_with('/') {
        return None;
    }

    // Parse as a RelativeStorePath (uses logical store dir from the file)
    let relative = RelativeStorePath::from_path(store_dir, &path_str).ok()?;

    let file_info = fs.get_file_info(&relative).await?;

    let name = {
        let name = if relative.relative_path.is_empty() {
            String::new()
        } else {
            std::path::Path::new(&*relative.relative_path)
                .file_name()
                .and_then(|f| f.to_str())
                .map(ToOwned::to_owned)
                .unwrap_or_default()
        };
        if VALIDATE_PRODUCT_NAME.is_match(&name) {
            name
        } else {
            String::new()
        }
    };

    let sha256hash = if file_info.is_regular {
        fs.hash_file(&relative).await
    } else {
        None
    };

    Some(BuildProduct {
        r#type: captures[1].to_string(),
        subtype: captures[2].to_string(),
        path: relative,
        default_path: captures
            .get(5)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default(),
        name,
        is_regular: file_info.is_regular,
        file_size: if file_info.is_regular {
            Some(file_info.size)
        } else {
            None
        },
        sha256hash,
    })
}

impl NixSupport {
    /// Monoidal combine: merge another `NixSupport` into this one.
    ///
    /// - `failed`: OR (any output failed → whole build failed)
    /// - `hydra_release_name`: last wins
    /// - `metrics`: last wins per name
    /// - `products`: append
    pub fn combine(&mut self, other: Self) {
        self.failed |= other.failed;
        if other.hydra_release_name.is_some() {
            self.hydra_release_name = other.hydra_release_name;
        }
        self.metrics.extend(other.metrics);
        self.products.extend(other.products);
    }
}

/// Parse `nix-support/` files for a single output.
///
/// `store_dir` is the logical store directory (e.g. `/nix/store`), used to
/// parse paths found inside `hydra-build-products` files.
///
/// `real_store_dir` is where the store objects actually live on the filesystem.
///
/// `fs` provides filesystem access for build product metadata and hashing
/// (see [`FilesystemOperations`] for the real implementation).
pub async fn parse_nix_support_for_output<F: FsOperations>(
    store_dir: &harmonia_store_path::StoreDir,
    real_store_dir: &std::path::Path,
    fs: &F,
    output_name: &OutputName,
    output: &StorePath,
) -> anyhow::Result<NixSupport> {
    let output_full_path = real_path(real_store_dir, output);

    let mut metrics = BTreeMap::new();
    let file_path = output_full_path.join("nix-support/hydra-metrics");
    if let Ok(file) = fs_err::tokio::File::open(&file_path).await {
        let reader = BufReader::new(file);
        let mut lines = reader.lines();
        while let Some(line) = lines.next_line().await? {
            if let Some((name, m)) = parse_metric(&line) {
                metrics.insert(name, m);
            }
        }
    }

    let failed = fs_err::tokio::try_exists(output_full_path.join("nix-support/failed"))
        .await
        .unwrap_or_default();

    let hydra_release_name = if let Ok(v) =
        fs_err::tokio::read_to_string(output_full_path.join("nix-support/hydra-release-name")).await
    {
        parse_release_name(&v)
    } else {
        None
    };

    let mut products = Vec::new();
    let products_path = output_full_path.join("nix-support/hydra-build-products");
    if let Ok(file) = fs_err::tokio::File::open(&products_path).await {
        let reader = BufReader::new(file);
        let mut lines = reader.lines();
        while let Some(line) = lines.next_line().await? {
            if let Some(o) = Box::pin(parse_build_product(store_dir, fs, &line)).await {
                products.push(o);
            }
        }
    } else {
        // No explicit products — add the output itself as a "nix-build" product
        let output_rel = RelativeStorePath {
            base_path: output.clone(),
            relative_path: "".into(),
        };
        if let Some(info) = fs.get_file_info(&output_rel).await {
            if !info.is_regular {
                products.push(BuildProduct {
                    r#type: "nix-build".to_string(),
                    subtype: if output_name.as_ref() == "out" {
                        String::new()
                    } else {
                        output_name.to_string()
                    },
                    path: output_rel,
                    name: output.name().to_string(),
                    default_path: String::new(),
                    is_regular: false,
                    file_size: None,
                    sha256hash: None,
                });
            }
        }
    }

    Ok(NixSupport {
        failed,
        hydra_release_name,
        metrics,
        products,
    })
}

/// Parse `nix-support/` files from all outputs, returning per-output data.
pub async fn parse_nix_support_from_outputs<F: FsOperations>(
    store_dir: &harmonia_store_path::StoreDir,
    real_store_dir: &std::path::Path,
    fs: &F,
    derivation_outputs: &BTreeMap<OutputName, StorePath>,
) -> anyhow::Result<BTreeMap<OutputName, NixSupport>> {
    let mut result = BTreeMap::new();
    for (name, path) in derivation_outputs {
        let ns = parse_nix_support_for_output(store_dir, real_store_dir, fs, name, path).await?;
        result.insert(name.clone(), ns);
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[derive(Debug, Clone)]
    struct DummyFsOperations {
        valid_file: bool,
        metadata: FileMetadata,
        file_hash: Option<harmonia_utils_hash::Sha256>,
    }

    impl FsOperations for DummyFsOperations {
        async fn get_file_info(&self, _: &RelativeStorePath) -> Option<FileMetadata> {
            if self.valid_file {
                Some(self.metadata)
            } else {
                None
            }
        }

        async fn hash_file(&self, _: &RelativeStorePath) -> Option<harmonia_utils_hash::Sha256> {
            self.file_hash
        }
    }

    #[tokio::test]
    async fn test_build_product_with_mock() {
        let store_dir = StoreDir::default();
        let output: StorePath = "ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso"
            .parse()
            .unwrap();
        let line = format!("file iso /nix/store/{output}/iso/custom.iso");
        let fs = DummyFsOperations {
            valid_file: true,
            metadata: FileMetadata {
                is_regular: true,
                size: 12345,
            },
            file_hash: Some(
                harmonia_utils_hash::Sha256::from_slice(&[
                    0x43, 0x06, 0x15, 0x2c, 0x73, 0xd2, 0xa7, 0xa0, 0x1d, 0xba, 0xc1, 0x6b, 0xa4,
                    0x8f, 0x45, 0xfa, 0x4a, 0xe5, 0xb7, 0x46, 0xa1, 0xd2, 0x82, 0x63, 0x85, 0x24,
                    0xae, 0x2a, 0xe9, 0x3a, 0xf2, 0x10,
                ])
                .unwrap(),
            ),
        };
        let bp = parse_build_product(&store_dir, &fs, &line).await.unwrap();
        assert!(bp.is_regular);
        assert_eq!(bp.name, "custom.iso");
        assert_eq!(bp.r#type, "file");
        assert_eq!(bp.subtype, "iso");
        assert_eq!(bp.file_size, Some(12345));
        assert!(bp.sha256hash.is_some());
        assert_eq!(bp.path.base_path, output);
        assert_eq!(&*bp.path.relative_path, "iso/custom.iso");
    }

    #[tokio::test]
    async fn test_build_product_invalid_file_returns_none() {
        let store_dir = StoreDir::default();
        let line = "file iso /nix/store/ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso/iso/custom.iso";
        let fs = DummyFsOperations {
            valid_file: false,
            metadata: FileMetadata {
                is_regular: false,
                size: 0,
            },
            file_hash: None,
        };
        let bp = parse_build_product(&store_dir, &fs, line).await;
        assert!(bp.is_none());
    }

    #[test]
    fn test_parse_invalid_metric() {
        let m = parse_metric("nix-env.qaCount");
        assert!(m.is_none());
    }

    #[test]
    fn test_parse_metric_without_unit() {
        let (name, m) = parse_metric("nix-env.qaCount 4").unwrap();
        assert_eq!(name, "nix-env.qaCount");
        assert!((m.value - 4.0_f64).abs() < f64::EPSILON);
        assert_eq!(m.unit, None);
    }

    #[test]
    fn test_parse_metric_with_unit() {
        let (name, m) = parse_metric("xzy.time 123.321 s").unwrap();
        assert_eq!(name, "xzy.time");
        assert!((m.value - 123.321_f64).abs() < f64::EPSILON);
        assert_eq!(m.unit, Some("s".into()));
    }

    #[test]
    fn test_parse_metric_bad_value_skipped() {
        let m = parse_metric("nix-env.qaCount notanumber");
        assert!(m.is_none());
    }

    #[test]
    fn test_parse_release_name() {
        let o = parse_release_name("nixos-25.11pre708350");
        assert_eq!(o, Some("nixos-25.11pre708350".into()));
    }

    /// Create a fake store dir with a file at the given sub-path,
    /// returning the store dir path.
    async fn setup_fake_store(
        store_path_base: &str,
        sub_path: &str,
        contents: &[u8],
    ) -> std::path::PathBuf {
        let store_dir =
            std::env::temp_dir().join(format!("nix-support-test-{}", std::process::id()));
        let full_dir = store_dir.join(store_path_base);
        let file_path = full_dir.join(sub_path);
        tokio::fs::create_dir_all(file_path.parent().unwrap())
            .await
            .unwrap();
        tokio::fs::write(&file_path, contents).await.unwrap();
        store_dir
    }

    use harmonia_store_path::StoreDir;

    #[tokio::test]
    async fn test_build_product_regular_file() {
        let store_path_base = "ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso";
        let real_dir = setup_fake_store(store_path_base, "iso/custom.iso", b"fake iso data").await;

        // The hydra-build-products file uses the logical store dir
        let store_dir = StoreDir::new("/nix/store").unwrap();
        let line = format!("file iso /nix/store/{store_path_base}/iso/custom.iso");

        let bp = parse_build_product(
            &store_dir,
            &FilesystemOperations {
                real_store_dir: real_dir.clone(),
            },
            &line,
        )
        .await
        .unwrap();

        let expected_output: StorePath = store_path_base.parse().unwrap();
        assert!(bp.is_regular);
        assert_eq!(bp.name, "custom.iso");
        assert_eq!(bp.r#type, "file");
        assert_eq!(bp.subtype, "iso");
        assert_eq!(bp.file_size, Some(13));
        assert!(bp.sha256hash.is_some());
        assert_eq!(bp.path.base_path, expected_output);
        assert_eq!(&*bp.path.relative_path, "iso/custom.iso");

        tokio::fs::remove_dir_all(&real_dir).await.unwrap();
    }

    #[tokio::test]
    async fn test_build_product_rejects_outside_store() {
        let store_dir = StoreDir::default();
        let line = "file iso /tmp/evil/custom.iso";
        let fs = FilesystemOperations {
            real_store_dir: store_dir.to_path().to_owned(),
        };
        let bp = parse_build_product(&store_dir, &fs, &line).await;
        assert!(bp.is_none());
    }

    #[tokio::test]
    async fn test_build_product_output_path_has_empty_name() {
        let store_path_base = "ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-test-1.0";
        let real_dir =
            std::env::temp_dir().join(format!("nix-support-test-bare-{}", std::process::id()));
        let output_file = real_dir.join(store_path_base);
        tokio::fs::create_dir_all(&real_dir).await.unwrap();
        tokio::fs::write(&output_file, b"data").await.unwrap();

        let store_dir = StoreDir::new("/nix/store").unwrap();
        let line = format!("file binary /nix/store/{store_path_base}");
        let bp = parse_build_product(
            &store_dir,
            &FilesystemOperations {
                real_store_dir: real_dir.clone(),
            },
            &line,
        )
        .await
        .unwrap();

        // When the product path equals the output path, name should be empty
        assert_eq!(bp.name, "");

        tokio::fs::remove_dir_all(&real_dir).await.unwrap();
    }
}

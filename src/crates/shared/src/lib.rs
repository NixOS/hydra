#![deny(clippy::all)]
#![deny(clippy::pedantic)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![allow(clippy::missing_errors_doc)]

use std::{os::unix::fs::MetadataExt as _, sync::LazyLock};

use sha2::{Digest as _, Sha256};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, BufReader};

use nix_utils::{BaseStore as _, StorePath};

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

#[derive(Debug)]
pub struct BuildProduct {
    pub path: String,
    pub default_path: String,

    pub r#type: String,
    pub subtype: String,
    pub name: String,

    pub is_regular: bool,

    pub sha256hash: Option<String>,
    pub file_size: Option<u64>,
}

#[derive(Debug)]
pub struct BuildMetric {
    pub path: String,
    pub name: String,
    pub unit: Option<String>,
    pub value: f64,
}

#[derive(Debug)]
pub struct NixSupport {
    pub failed: bool,
    pub hydra_release_name: Option<String>,
    pub metrics: Vec<BuildMetric>,
    pub products: Vec<BuildProduct>,
}

#[derive(Debug, Clone)]
struct FileMetadata {
    is_regular: bool,
    size: u64,
}

trait FsOperations {
    fn is_inside_store(&self, path: &std::path::Path) -> bool;
    fn get_metadata(
        &self,
        path: impl AsRef<std::path::Path> + std::fmt::Debug,
    ) -> impl std::future::Future<Output = Result<FileMetadata, std::io::Error>>;
    fn get_file_hash(
        &self,
        path: impl Into<std::path::PathBuf> + std::fmt::Debug,
    ) -> impl std::future::Future<Output = tokio::io::Result<String>>;
}

#[derive(Debug, Clone)]
struct FilesystemOperations {
    nix_store_dir: std::sync::Arc<String>,
}

impl FilesystemOperations {
    fn new() -> Self {
        Self {
            nix_store_dir: std::sync::Arc::new(nix_utils::get_store_dir()),
        }
    }
}

impl FsOperations for FilesystemOperations {
    fn is_inside_store(&self, path: &std::path::Path) -> bool {
        nix_utils::is_subpath(std::path::Path::new(self.nix_store_dir.as_str()), path)
    }

    #[tracing::instrument(skip(self), err)]
    async fn get_metadata(
        &self,
        path: impl AsRef<std::path::Path> + std::fmt::Debug,
    ) -> Result<FileMetadata, std::io::Error> {
        let m = fs_err::tokio::metadata(path).await?;
        Ok(FileMetadata {
            is_regular: m.is_file(),
            size: m.size(),
        })
    }

    #[tracing::instrument(skip(self), err)]
    async fn get_file_hash(
        &self,
        path: impl Into<std::path::PathBuf> + std::fmt::Debug,
    ) -> tokio::io::Result<String> {
        let file = fs_err::tokio::File::open(path).await?;
        let mut reader = BufReader::new(file);

        let mut hasher = Sha256::new();
        let mut buf = [0u8; 16 * 1024];

        loop {
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
        }

        Ok(format!("{:x}", hasher.finalize()))
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

fn parse_metric(
    store: &nix_utils::LocalStore,
    line: &str,
    output: &StorePath,
) -> Option<BuildMetric> {
    let fields: Vec<String> = line.split_whitespace().map(ToOwned::to_owned).collect();
    if fields.len() < 2 || !VALIDATE_METRICS_NAME.is_match(&fields[0]) {
        return None;
    }

    Some(BuildMetric {
        path: store.print_store_path(output),
        name: fields[0].clone(),
        value: fields[1].parse::<f64>().unwrap_or(0.0),
        unit: if fields.len() >= 3 && VALIDATE_METRICS_UNIT.is_match(&fields[2]) {
            Some(fields[2].clone())
        } else {
            None
        },
    })
}

async fn parse_build_product<Op>(
    store: &nix_utils::LocalStore,
    handle: Op,
    output: &StorePath,
    line: &str,
) -> Option<BuildProduct>
where
    Op: FsOperations + Send + Sync + 'static,
{
    let captures = BUILD_PRODUCT_PARSER.captures(line)?;

    let s = captures[3].to_string();
    let path = if s.starts_with('"') && s.ends_with('"') {
        s[1..s.len() - 1].to_string()
    } else {
        s
    };

    if path.is_empty() || !path.starts_with('/') {
        return None;
    }
    if !handle.is_inside_store(std::path::Path::new(&path)) {
        return None;
    }
    let metadata = handle.get_metadata(&path).await.ok()?;

    let name = {
        let name = if path == store.print_store_path(output) {
            String::new()
        } else {
            std::path::Path::new(&path)
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

    let sha256hash = if metadata.is_regular {
        handle.get_file_hash(&path).await.ok()
    } else {
        None
    };

    Some(BuildProduct {
        r#type: captures[1].to_string(),
        subtype: captures[2].to_string(),
        path,
        default_path: captures
            .get(5)
            .map(|m| m.as_str().to_string())
            .unwrap_or_default(),
        name,
        is_regular: metadata.is_regular,
        file_size: if metadata.is_regular {
            Some(metadata.size)
        } else {
            None
        },
        sha256hash,
    })
}

#[tracing::instrument(skip(store), err)]
pub async fn parse_nix_support_from_outputs(
    store: &nix_utils::LocalStore,
    derivation_outputs: &[nix_utils::DerivationOutput],
) -> anyhow::Result<NixSupport> {
    let mut metrics = Vec::new();
    let mut failed = false;
    let mut hydra_release_name = None;

    let outputs = derivation_outputs
        .iter()
        .filter_map(|o| o.path.as_ref())
        .collect::<Vec<_>>();
    for output in &outputs {
        let output_full_path = store.print_store_path(output);
        let file_path = std::path::Path::new(&output_full_path).join("nix-support/hydra-metrics");
        let Ok(file) = fs_err::tokio::File::open(&file_path).await else {
            continue;
        };

        let reader = BufReader::new(file);
        let mut lines = reader.lines();

        while let Some(line) = lines.next_line().await? {
            if let Some(m) = parse_metric(store, &line, output) {
                metrics.push(m);
            }
        }
    }

    for output in &outputs {
        let file_path =
            std::path::Path::new(&store.print_store_path(output)).join("nix-support/failed");
        if fs_err::tokio::try_exists(file_path)
            .await
            .unwrap_or_default()
        {
            failed = true;
            break;
        }
    }

    for output in &outputs {
        let file_path = std::path::Path::new(&store.print_store_path(output))
            .join("nix-support/hydra-release-name");
        if let Ok(v) = fs_err::tokio::read_to_string(file_path).await
            && let Some(v) = parse_release_name(&v)
        {
            hydra_release_name = Some(v);
            break;
        }
    }

    let mut explicit_products = false;
    let mut products = Vec::new();
    for output in &outputs {
        let output_full_path = store.print_store_path(output);
        let file_path =
            std::path::Path::new(&output_full_path).join("nix-support/hydra-build-products");
        let Ok(file) = fs_err::tokio::File::open(&file_path).await else {
            continue;
        };

        explicit_products = true;

        let reader = BufReader::new(file);
        let mut lines = reader.lines();
        let fsop = FilesystemOperations::new();
        while let Some(line) = lines.next_line().await? {
            if let Some(o) = Box::pin(parse_build_product(store, fsop.clone(), output, &line)).await
            {
                products.push(o);
            }
        }
    }

    if !explicit_products {
        for o in derivation_outputs {
            let Some(path) = &o.path else {
                continue;
            };
            let full_path = store.print_store_path(path);
            let Ok(metadata) = fs_err::tokio::metadata(&full_path).await else {
                continue;
            };
            if metadata.is_dir() {
                products.push(BuildProduct {
                    r#type: "nix-build".to_string(),
                    subtype: if o.name == "out" {
                        String::new()
                    } else {
                        o.name.clone()
                    },
                    path: full_path,
                    name: path.name().to_string(),
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

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[derive(Debug, Clone)]
    struct DummyFsOperations {
        valid_file: bool,
        metadata: FileMetadata,
        file_hash: String,
    }

    impl FsOperations for DummyFsOperations {
        fn is_inside_store(&self, _: &std::path::Path) -> bool {
            self.valid_file
        }

        async fn get_metadata(
            &self,
            _: impl AsRef<std::path::Path> + std::fmt::Debug,
        ) -> Result<FileMetadata, std::io::Error> {
            Ok(self.metadata.clone())
        }

        async fn get_file_hash(
            &self,
            _: impl Into<std::path::PathBuf> + std::fmt::Debug,
        ) -> Result<String, std::io::Error> {
            Ok(self.file_hash.clone())
        }
    }

    #[tokio::test]
    async fn test_build_products() {
        let store = nix_utils::LocalStore::init();
        let output = nix_utils::StorePath::new("ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso");
        let line = format!(
            "file iso {}/iso/custom.iso",
            store.print_store_path(&output)
        );
        let fsop = DummyFsOperations {
            valid_file: true,
            metadata: FileMetadata {
                is_regular: true,
                size: 12345,
            },
            file_hash: "4306152c73d2a7a01dbac16ba48f45fa4ae5b746a1d282638524ae2ae93af210".into(),
        };
        let build_product = parse_build_product(&store, fsop, &output, &line)
            .await
            .unwrap();
        assert!(build_product.is_regular);
        assert_eq!(
            build_product.path,
            "/nix/store/ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso/iso/custom.iso"
        );
        assert_eq!(build_product.name, "custom.iso");
        assert_eq!(build_product.file_size, Some(12345));
        assert_eq!(
            build_product.sha256hash,
            Some("4306152c73d2a7a01dbac16ba48f45fa4ae5b746a1d282638524ae2ae93af210".into())
        );
    }

    #[test]
    fn test_parse_invalid_metric() {
        let output = nix_utils::StorePath::new("ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso");
        let line = "nix-env.qaCount";
        let store = nix_utils::LocalStore::init();
        let m = parse_metric(&store, line, &output);
        assert!(m.is_none());
    }

    #[test]
    fn test_parse_metric_without_unit() {
        let output = nix_utils::StorePath::new("ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso");
        let line = "nix-env.qaCount 4";
        let store = nix_utils::LocalStore::init();
        let m = parse_metric(&store, line, &output).unwrap();
        assert_eq!(m.name, "nix-env.qaCount");
        assert!((m.value - 4.0_f64).abs() < f64::EPSILON);
        assert_eq!(m.unit, None);
    }

    #[test]
    fn test_parse_metric_with_unit() {
        let output = nix_utils::StorePath::new("ir3rqjyj5cz3js5lr7d0zw0gn6crzs6w-custom.iso");
        let line = "xzy.time 123.321 s";
        let store = nix_utils::LocalStore::init();
        let m = parse_metric(&store, line, &output).unwrap();
        assert_eq!(m.name, "xzy.time");
        assert!((m.value - 123.321_f64).abs() < f64::EPSILON);
        assert_eq!(m.unit, Some("s".into()));
    }

    #[test]
    fn test_parse_release_name() {
        let line = "nixos-25.11pre708350";
        let o = parse_release_name(line);
        assert_eq!(o, Some("nixos-25.11pre708350".into()));
    }
}

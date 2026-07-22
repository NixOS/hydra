//! Reconstruct a [`BuildOutput`] for a cached build by streaming its NARs
//! from the binary cache, instead of substituting the outputs into the local
//! store just to read their `nix-support/*` files (which fills the disk).
//!
//! Mirroring the old C++ queue runner's `NarMemberDatas`, we record each
//! member's type, size and sha256, and buffer the contents of the few small
//! `nix-support` files. Streaming keeps memory bounded for large outputs.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};

use futures::StreamExt as _;
use sha2::{Digest as _, Sha256};
use tokio::io::{AsyncRead, AsyncReadExt as _};

use harmonia_file_core::{FileSystemObject, FileTree};
use harmonia_file_nar::{NarEvent, NarFileInfo, parse_nar};
use harmonia_store_derivation::derived_path::OutputName;
use harmonia_store_path::{StoreDir, StorePath};
use nix_support::{FileMetadata, FsOperations, NixSupport};
use store_path_utils::RelativeStorePath;

use super::build::{BuildOutput, BuildTimings};

/// `nix-support` files whose full contents we keep in memory while streaming;
/// everything else only needs metadata and a hash.
const KEPT_FILES: [&str; 3] = [
    "nix-support/hydra-build-products",
    "nix-support/hydra-release-name",
    "nix-support/hydra-metrics",
];

/// Upper bound on the size of a `nix-support` file we buffer in memory. These
/// files are tiny in practice; a hostile or corrupt cache could otherwise make
/// us allocate an arbitrary amount. Larger files are hashed but their contents
/// are dropped, so they parse as empty.
const MAX_KEPT_FILE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Debug)]
struct Member {
    is_regular: bool,
    size: u64,
    sha256: Option<harmonia_utils_hash::Sha256>,
    contents: Option<Vec<u8>>,
}

impl Member {
    /// A directory or symlink: only its existence and non-regular type matter.
    fn non_regular() -> Self {
        Self {
            is_regular: false,
            size: 0,
            sha256: None,
            contents: None,
        }
    }
}

/// In-memory view of one or more output NARs, implementing [`FsOperations`]
/// so the shared `nix-support` parser can run against cached outputs.
#[derive(Debug, Default)]
pub(super) struct NarMemberFs {
    members: HashMap<(StorePath, String), Member>,
}

impl NarMemberFs {
    fn key(path: &RelativeStorePath) -> (StorePath, String) {
        (path.base_path.clone(), path.relative_path.to_string())
    }

    /// Stream a single output's NAR, recording every member.
    async fn ingest<R: AsyncRead + Unpin>(
        &mut self,
        output: &StorePath,
        reader: R,
    ) -> std::io::Result<()> {
        let mut stream = std::pin::pin!(parse_nar(reader));
        // Path components from the NAR root to the current node; the root
        // directory has an empty name that joins away.
        let mut stack: Vec<String> = Vec::new();

        while let Some(event) = stream.next().await {
            let (rel, member) = match event? {
                NarEvent::StartDirectory { name } => {
                    stack.push(nar_name(&name)?);
                    (join(&stack), Member::non_regular())
                }
                NarEvent::EndDirectory => {
                    stack.pop();
                    continue;
                }
                NarEvent::Symlink { name, .. } => {
                    (entry_path(&stack, &name)?, Member::non_regular())
                }
                NarEvent::File {
                    name, size, reader, ..
                } => {
                    let rel = entry_path(&stack, &name)?;
                    let member = self.read_file_member(output, &rel, size, reader).await?;
                    (rel, member)
                }
            };
            self.members.insert((output.clone(), rel), member);
        }
        Ok(())
    }

    /// Hash a file's contents while streaming, buffering them only for the
    /// small `nix-support` files we later parse.
    async fn read_file_member<R: AsyncRead + Unpin>(
        &self,
        output: &StorePath,
        rel: &str,
        size: u64,
        mut reader: R,
    ) -> std::io::Result<Member> {
        let mut keep = KEPT_FILES.contains(&rel);
        if keep && size > MAX_KEPT_FILE_BYTES {
            tracing::warn!(
                "nix-support file {output}/{rel} is {size} bytes, over the \
                 {MAX_KEPT_FILE_BYTES} byte limit; ignoring its contents"
            );
            keep = false;
        }

        let mut hasher = Sha256::new();
        let mut contents = keep.then(Vec::new);
        // Heap-allocated so the streaming future stays small.
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let n = reader.read(&mut buf).await?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            if let Some(c) = contents.as_mut() {
                c.extend_from_slice(&buf[..n]);
            }
        }

        Ok(Member {
            is_regular: true,
            size,
            sha256: harmonia_utils_hash::Sha256::from_slice(&hasher.finalize()).ok(),
            contents,
        })
    }
}

/// Filesystem view of a single output backed by its `.ls` NAR listing: the
/// file tree with sizes and types, but no contents or hashes. Sufficient for
/// outputs without `nix-support` content files, where only metadata and the
/// default `nix-build` product are needed. Keyed by path relative to the
/// output, since a listing only ever describes one output.
#[derive(Debug, Default)]
pub(super) struct LsListingFs {
    members: HashMap<Box<str>, FileMetadata>,
}

impl LsListingFs {
    fn from_tree(tree: &FileTree<NarFileInfo>) -> Self {
        let mut fs = Self::default();
        fs.walk(String::new(), tree);
        fs
    }

    fn walk(&mut self, rel: String, tree: &FileTree<NarFileInfo>) {
        const NON_REGULAR: FileMetadata = FileMetadata {
            is_regular: false,
            size: 0,
        };
        let meta = match &tree.0 {
            FileSystemObject::Regular(r) => FileMetadata {
                is_regular: true,
                size: r.contents.size,
            },
            FileSystemObject::Directory(dir) => {
                for (name, child) in &dir.entries {
                    let child_rel = if rel.is_empty() {
                        name.clone()
                    } else {
                        format!("{rel}/{name}")
                    };
                    self.walk(child_rel, child);
                }
                NON_REGULAR
            }
            FileSystemObject::Symlink(_) => NON_REGULAR,
        };
        self.members.insert(rel.into(), meta);
    }

    /// Whether any `nix-support` file whose contents we need is present, in
    /// which case the listing is insufficient and the NAR must be read.
    fn needs_nar(&self) -> bool {
        KEPT_FILES.iter().any(|f| self.members.contains_key(*f))
    }
}

impl FsOperations for LsListingFs {
    async fn get_file_info(&self, path: &RelativeStorePath) -> Option<FileMetadata> {
        self.members.get(path.relative_path.as_ref()).copied()
    }

    async fn hash_file(&self, _path: &RelativeStorePath) -> Option<harmonia_utils_hash::Sha256> {
        None
    }

    async fn read_file(&self, _path: &RelativeStorePath) -> Option<Vec<u8>> {
        None
    }
}

/// Decode a NAR entry name, rejecting non-UTF-8 to avoid lossy store paths.
fn nar_name(name: &[u8]) -> std::io::Result<String> {
    std::str::from_utf8(name)
        .map(ToOwned::to_owned)
        .map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidData, "non-UTF-8 name in NAR"))
}

/// Relative path of the directory stack joined with `/`.
fn join(stack: &[String]) -> String {
    stack
        .iter()
        .map(String::as_str)
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("/")
}

/// Relative path of an entry named `name` within the current directory stack.
fn entry_path(stack: &[String], name: &[u8]) -> std::io::Result<String> {
    let mut rel = join(stack);
    if !rel.is_empty() {
        rel.push('/');
    }
    rel.push_str(&nar_name(name)?);
    Ok(rel)
}

impl FsOperations for NarMemberFs {
    async fn get_file_info(&self, path: &RelativeStorePath) -> Option<FileMetadata> {
        self.members.get(&Self::key(path)).map(|m| FileMetadata {
            is_regular: m.is_regular,
            size: m.size,
        })
    }

    async fn hash_file(&self, path: &RelativeStorePath) -> Option<harmonia_utils_hash::Sha256> {
        self.members.get(&Self::key(path)).and_then(|m| m.sha256)
    }

    async fn read_file(&self, path: &RelativeStorePath) -> Option<Vec<u8>> {
        self.members
            .get(&Self::key(path))
            .and_then(|m| m.contents.clone())
    }
}

/// Sum the NAR size of the closure reachable from `outputs`, following
/// references via narinfo lookups against the cache. Also returns the summed
/// NAR size of the outputs themselves.
async fn closure_and_output_size(
    store: &binary_cache::S3BinaryCacheClient,
    outputs: &[StorePath],
) -> Result<(u64, u64), binary_cache::CacheError> {
    let mut seen: HashSet<StorePath> = HashSet::new();
    let mut queue: VecDeque<StorePath> = outputs.iter().cloned().collect();
    let mut closure_size = 0;
    while let Some(path) = queue.pop_front() {
        if !seen.insert(path.clone()) {
            continue;
        }
        let Some(narinfo) = store.download_narinfo(&path).await? else {
            continue;
        };
        closure_size += narinfo.info.info.nar_size;
        for reference in &narinfo.info.info.references {
            if !seen.contains(reference) {
                queue.push_back(reference.clone());
            }
        }
    }

    let mut output_size = 0;
    for output in outputs {
        if let Some(narinfo) = store.download_narinfo(output).await? {
            output_size += narinfo.info.info.nar_size;
        }
    }

    Ok((closure_size, output_size))
}

/// Reconstruct one output's [`NixSupport`] by streaming and decompressing its
/// NAR from the cache. Used when no `.ls` listing is available or the output
/// has `nix-support` files whose contents we must read.
async fn nix_support_from_nar(
    store: &binary_cache::S3BinaryCacheClient,
    store_dir: &StoreDir,
    name: &OutputName,
    output: &StorePath,
) -> Result<NixSupport, binary_cache::CacheError> {
    let Some((_narinfo, reader)) = store.open_nar_stream(output).await? else {
        tracing::warn!("no narinfo for cached output {output}; skipping nix-support");
        return Ok(NixSupport::default());
    };
    let mut fs = NarMemberFs::default();
    fs.ingest(output, reader).await?;
    Ok(Box::pin(nix_support::parse_nix_support_for_output(
        store_dir, &fs, name, output,
    ))
    .await?)
}

/// Build a [`BuildOutput`] for a cached build by reading its outputs from the
/// binary cache instead of the local store.
pub(super) async fn build_output_from_cache(
    store: &binary_cache::S3BinaryCacheClient,
    store_dir: &StoreDir,
    output_paths: &BTreeMap<OutputName, Option<StorePath>>,
) -> Result<BuildOutput, binary_cache::CacheError> {
    let resolved: BTreeMap<OutputName, StorePath> = output_paths
        .iter()
        .filter_map(|(name, path)| Some((name.clone(), path.as_ref()?.clone())))
        .collect();

    let mut merged = NixSupport::default();
    for (name, output) in &resolved {
        // Prefer the cheap `.ls` listing: most outputs have no nix-support
        // content files, so their BuildOutput can be reconstructed from
        // metadata alone without decompressing the (potentially large) NAR.
        // Any problem fetching/parsing the listing degrades to the NAR path.
        let listing = match store.download_listing(output).await {
            Ok(Some(tree)) => Some(LsListingFs::from_tree(&tree)),
            Ok(None) => None,
            Err(e) => {
                tracing::warn!(
                    "listing unavailable for cached output {output} ({e}); \
                     falling back to NAR"
                );
                None
            }
        };
        let ns = match listing {
            Some(listing) if !listing.needs_nar() => {
                Box::pin(nix_support::parse_nix_support_for_output(
                    store_dir, &listing, name, output,
                ))
                .await?
            }
            // Listing absent, unreadable, or the output has nix-support
            // content files we must read: stream the NAR.
            _ => nix_support_from_nar(store, store_dir, name, output).await?,
        };
        merged.combine(ns);
    }

    let resolved_paths: Vec<StorePath> = resolved.values().cloned().collect();
    let (closure_size, size) = closure_and_output_size(store, &resolved_paths).await?;

    Ok(BuildOutput {
        failed: merged.failed,
        timings: BuildTimings::default(),
        release_name: merged.hydra_release_name,
        closure_size,
        size,
        products: merged.products,
        outputs: resolved,
        metrics: merged.metrics,
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;
    use harmonia_file_nar::archive::test_data::TestNarEvent;
    use nix_support::BuildProduct;

    fn out_path() -> StorePath {
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-cached-1.0"
            .parse()
            .unwrap()
    }

    fn nar_bytes(events: &[TestNarEvent]) -> Vec<u8> {
        harmonia_file_nar::archive::write_nar(events).to_vec()
    }

    fn name(s: &str) -> bytes::Bytes {
        bytes::Bytes::copy_from_slice(s.as_bytes())
    }

    fn file(file_name: &str, contents: &[u8]) -> TestNarEvent {
        let contents = bytes::Bytes::copy_from_slice(contents);
        NarEvent::File {
            name: name(file_name),
            executable: false,
            size: contents.len() as u64,
            reader: std::io::Cursor::new(contents),
        }
    }

    fn start_dir(dir_name: &str) -> TestNarEvent {
        NarEvent::StartDirectory {
            name: name(dir_name),
        }
    }

    #[tokio::test]
    async fn extracts_build_products_and_metrics_from_nar() {
        let output = out_path();
        let products = format!("file json /nix/store/{output}/data.json\n");
        let events = vec![
            start_dir(""),
            start_dir("nix-support"),
            file("hydra-build-products", products.as_bytes()),
            file("hydra-metrics", b"coverage 87.5 %\n"),
            file("hydra-release-name", b"cached-1.0\n"),
            NarEvent::EndDirectory,
            file("data.json", b"{}"),
            NarEvent::EndDirectory,
        ];

        let mut fs = NarMemberFs::default();
        let reader = std::io::Cursor::new(nar_bytes(&events));
        fs.ingest(&output, reader).await.unwrap();

        let store_dir = StoreDir::new("/nix/store").unwrap();
        let outputs: BTreeMap<OutputName, StorePath> =
            BTreeMap::from([("out".parse().unwrap(), output.clone())]);
        let per_output = nix_support::parse_nix_support_from_outputs(&store_dir, &fs, &outputs)
            .await
            .unwrap();
        let mut merged = NixSupport::default();
        for ns in per_output.into_values() {
            merged.combine(ns);
        }

        assert_eq!(merged.hydra_release_name.as_deref(), Some("cached-1.0"));
        assert_eq!(merged.metrics.get("coverage").map(|m| m.value), Some(87.5));
        assert_eq!(merged.products.len(), 1);
        let product = &merged.products[0];
        assert_eq!(product.r#type, "file");
        assert_eq!(product.subtype, "json");
        assert_eq!(product.name, "data.json");
        assert!(product.is_regular);
        assert_eq!(product.file_size, Some(2));
        assert!(product.sha256hash.is_some());
        assert_eq!(&*product.path.relative_path, "data.json");
    }

    #[tokio::test]
    async fn no_explicit_products_yields_nix_build_product() {
        let output = out_path();
        let events = vec![
            start_dir(""),
            file("hello", b"world"),
            NarEvent::EndDirectory,
        ];

        let mut fs = NarMemberFs::default();
        let reader = std::io::Cursor::new(nar_bytes(&events));
        fs.ingest(&output, reader).await.unwrap();

        let store_dir = StoreDir::new("/nix/store").unwrap();
        let outputs: BTreeMap<OutputName, StorePath> =
            BTreeMap::from([("out".parse().unwrap(), output.clone())]);
        let per_output = nix_support::parse_nix_support_from_outputs(&store_dir, &fs, &outputs)
            .await
            .unwrap();
        let ns = per_output.into_values().next().unwrap();

        assert_eq!(ns.products.len(), 1);
        assert_eq!(ns.products[0].r#type, "nix-build");
        assert!(ns.products[0].path.relative_path.is_empty());
    }

    async fn parse_products(output: &StorePath, products_line: &str) -> Vec<BuildProduct> {
        let events = vec![
            start_dir(""),
            start_dir("nix-support"),
            file(
                "hydra-build-products",
                format!("{products_line}\n").as_bytes(),
            ),
            NarEvent::EndDirectory,
            NarEvent::EndDirectory,
        ];
        let mut fs = NarMemberFs::default();
        fs.ingest(output, std::io::Cursor::new(nar_bytes(&events)))
            .await
            .unwrap();

        let store_dir = StoreDir::new("/nix/store").unwrap();
        let outputs: BTreeMap<OutputName, StorePath> =
            BTreeMap::from([("out".parse().unwrap(), output.clone())]);
        nix_support::parse_nix_support_from_outputs(&store_dir, &fs, &outputs)
            .await
            .unwrap()
            .into_values()
            .next()
            .unwrap()
            .products
    }

    #[tokio::test]
    async fn build_product_pointing_outside_ingested_nar_is_dropped() {
        // A product referencing a *different* store path is not part of any
        // NAR we streamed, so it must not appear (and must not be hashed).
        let output = out_path();
        let other = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-other-1.0";
        let products =
            parse_products(&output, &format!("file json /nix/store/{other}/data.json")).await;
        assert!(products.is_empty());
    }

    #[tokio::test]
    async fn build_product_with_traversal_path_is_dropped() {
        let output = out_path();
        let products = parse_products(&output, "file evil /etc/passwd").await;
        assert!(products.is_empty());
    }

    fn dir(entries: Vec<(&str, FileTree<NarFileInfo>)>) -> FileTree<NarFileInfo> {
        FileTree(FileSystemObject::Directory(harmonia_file_core::Directory {
            entries: entries
                .into_iter()
                .map(|(k, v)| (k.to_string(), Box::new(v)))
                .collect(),
        }))
    }

    fn reg(size: u64) -> FileTree<NarFileInfo> {
        FileTree(FileSystemObject::Regular(harmonia_file_core::Regular {
            executable: false,
            contents: NarFileInfo {
                size,
                nar_offset: None,
            },
        }))
    }

    #[tokio::test]
    async fn listing_without_nix_support_yields_default_product() {
        // A directory output with no nix-support: the cheap listing path must
        // produce the default "nix-build" product without touching the NAR.
        let output = out_path();
        let tree = dir(vec![("bin", dir(vec![("hello", reg(42))]))]);
        let fs = LsListingFs::from_tree(&tree);
        assert!(!fs.needs_nar());

        let store_dir = StoreDir::new("/nix/store").unwrap();
        let ns = nix_support::parse_nix_support_for_output(
            &store_dir,
            &fs,
            &"out".parse().unwrap(),
            &output,
        )
        .await
        .unwrap();
        assert_eq!(ns.products.len(), 1);
        assert_eq!(ns.products[0].r#type, "nix-build");
        assert!(ns.products[0].path.relative_path.is_empty());
        assert!(ns.products[0].sha256hash.is_none());
    }

    #[tokio::test]
    async fn non_utf8_names_are_rejected() {
        let output = out_path();
        let events = vec![
            start_dir(""),
            NarEvent::File {
                name: bytes::Bytes::from_static(&[0xff, 0xfe]),
                executable: false,
                size: 1,
                reader: std::io::Cursor::new(bytes::Bytes::from_static(b"x")),
            },
            NarEvent::EndDirectory,
        ];
        let mut fs = NarMemberFs::default();
        let err = fs
            .ingest(&output, std::io::Cursor::new(nar_bytes(&events)))
            .await
            .unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }
}

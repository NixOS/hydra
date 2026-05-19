use sha2::Digest;
use std::{env, path::PathBuf};

#[derive(Debug, thiserror::Error)]
enum BuildError {
    #[error(transparent)]
    Var(#[from] env::VarError),
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

fn main() -> Result<(), BuildError> {
    let out_dir = PathBuf::from(env::var("OUT_DIR")?);

    let workspace_version = env::var("CARGO_PKG_VERSION")?;

    println!("cargo:rerun-if-changed=../../proto/v1/streaming.proto");
    println!("cargo:rerun-if-changed=../../proto/v1/store.proto");
    println!("cargo:rerun-if-changed=../../proto/v1/nix-support.proto");

    let mut hasher = sha2::Sha256::new();
    hasher.update(fs_err::read_to_string("../../proto/v1/streaming.proto")?.as_bytes());
    hasher.update(fs_err::read_to_string("../../proto/v1/nix-support.proto")?.as_bytes());
    let proto_hash = format!("{:x}", hasher.finalize());
    let version = format!("{}-{}", workspace_version, &proto_hash[..8]);

    fs_err::write(
        out_dir.join("proto_version.rs"),
        format!(
            r#"// Generated during build - do not edit
pub const PROTO_API_VERSION: &str = "{version}";
"#
        ),
    )?;

    // First pass: generate nix.store.v1 types (except StorePath which is manual)
    tonic_prost_build::configure()
        .extern_path(
            ".nix.store.v1.StorePath",
            "crate::store_path::ProtoStorePath",
        )
        .build_client(false)
        .build_server(false)
        .compile_protos(&["../../proto/v1/store.proto"], &["../../proto"])?;

    // Second pass: generate runner.v1 (references nix.store.v1 via extern_path)
    tonic_prost_build::configure()
        .extern_path(
            ".nix.store.v1.StorePath",
            "crate::store_path::ProtoStorePath",
        )
        .extern_path(".nix.store.v1", "crate::nix::store::v1")
        .build_client(cfg!(feature = "client"))
        .build_server(cfg!(feature = "server"))
        .file_descriptor_set_path(out_dir.join("streaming_descriptor.bin"))
        .compile_protos(
            &[
                "../../proto/v1/nix-support.proto",
                "../../proto/v1/streaming.proto",
            ],
            &["../../proto"],
        )?;
    Ok(())
}

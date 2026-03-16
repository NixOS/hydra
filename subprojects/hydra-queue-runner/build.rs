use sha2::Digest;
use std::{env, path::PathBuf};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let out_dir = PathBuf::from(env::var("OUT_DIR")?);

    let workspace_version = env::var("CARGO_PKG_VERSION")?;

    let proto_path = "../proto/v1/streaming.proto";
    let proto_content = fs_err::read_to_string(proto_path)?;
    let mut hasher = sha2::Sha256::new();
    hasher.update(proto_content.as_bytes());
    let proto_hash = format!("{:x}", hasher.finalize());
    let version = format!("{}-{}", workspace_version, &proto_hash[..8]);

    // Generate version module
    fs_err::write(
        out_dir.join("proto_version.rs"),
        format!(
            r#"// Generated during build - do not edit
pub const PROTO_API_VERSION: &str = "{version}";
"#
        ),
    )?;

    tonic_prost_build::configure()
        .file_descriptor_set_path(out_dir.join("streaming_descriptor.bin"))
        .compile_protos(&["../proto/v1/streaming.proto"], &["../proto"])?;
    Ok(())
}

{
  lib,
  version,

  rustPlatform,

  protobuf,
  pkg-config,
  rust-jemalloc-sys,
  withOtel ? false,
}:

rustPlatform.buildRustPackage {
  pname = "hydra-builder";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../.cargo
      ../../subprojects/hydra-builder/Cargo.toml
      ../../subprojects/hydra-builder/src
      ../../subprojects/crates
      # For unit tests which want to spin up a fresh database
      ../../subprojects/hydra/sql/hydra.sql
      ../../subprojects/proto
    ];
  };

  cargoLock = {
    lockFile = ../../Cargo.lock;
    outputHashes = import ../../packaging/cargo-output-hashes.nix;
  };

  # The source fileset above intentionally excludes hydra-queue-runner, ...,
  # so drop it from the workspace members to keep cargo from trying to
  # load its (absent) manifest.
  postPatch = ''
    sed -i \
      -e 's|"subprojects/hydra-queue-runner",||' \
      -e 's|"subprojects/hydra-ws",||' \
      Cargo.toml
  '';

  buildAndTestSubdir = "subprojects/hydra-builder";
  buildFeatures = lib.optional withOtel "otel";

  nativeBuildInputs = [
    pkg-config
    protobuf
  ];

  buildInputs = [
    protobuf
    rust-jemalloc-sys
  ];

  # FIXME: get these passing in a prod build
  doCheck = false;

  meta.description = "Hydra builder (Rust)";
}

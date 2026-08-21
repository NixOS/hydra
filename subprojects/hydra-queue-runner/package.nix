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
  pname = "hydra-queue-runner";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../.cargo
      ../../.sqlx
      ../../subprojects/hydra-queue-runner/Cargo.toml
      ../../subprojects/hydra-queue-runner/src
      ../../subprojects/hydra-queue-runner/examples
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

  # Drop the other Rust binary crates from the workspace; their sources
  # are excluded from the fileset above, so cargo would otherwise fail
  # trying to load their (absent) manifests.
  postPatch = ''
    sed -i '/hydra-queue-runner/!{/"subprojects\/hydra-/d;}' Cargo.toml
  '';

  buildAndTestSubdir = "subprojects/hydra-queue-runner";
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

  meta.description = "Hydra queue runner (Rust)";
}

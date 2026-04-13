{
  lib,
  version,

  rustPlatform,

  nixComponents,
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
      ../../subprojects/hydra-queue-runner/build.rs
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
    outputHashes = {
      "harmonia-store-core-0.0.0-alpha.0" = "sha256-g7JJGrjWnnzBtxtxLaqL/wKehPBZAHh8C7U7ALYW6o0=";
    };
  };

  # The source fileset above intentionally excludes hydra-builder,
  # so drop it from the workspace members to keep cargo from trying to
  # load its (absent) manifest.
  postPatch = ''
    sed -i 's|"subprojects/hydra-builder", ||' Cargo.toml
  '';

  buildAndTestSubdir = "subprojects/hydra-queue-runner";
  buildFeatures = lib.optional withOtel "otel";

  nativeBuildInputs = [
    pkg-config
    protobuf
  ];

  buildInputs = [
    nixComponents.nix-main
    protobuf
    rust-jemalloc-sys
  ];

  # FIXME: get these passing in a prod build
  doCheck = false;

  meta.description = "Hydra queue runner (Rust)";
}

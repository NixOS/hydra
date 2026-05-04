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
  pname = "hydra-builder";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../.cargo
      ../../subprojects/hydra-builder/Cargo.toml
      ../../subprojects/hydra-builder/build.rs
      ../../subprojects/hydra-builder/src
      ../../subprojects/crates
      # For unit tests which want to spin up a fresh database
      ../../subprojects/hydra/sql/hydra.sql
      ../../subprojects/proto
    ];
  };

  cargoLock = {
    lockFile = ../../Cargo.lock;
    outputHashes = {
      "harmonia-store-core-0.0.0-alpha.0" = "sha256-EwOfW4esHMOaxoxgrguLJYLPQXoFjzOljR2+x+mmo3k=";
    };
  };

  # The source fileset above intentionally excludes hydra-queue-runner,
  # so drop it from the workspace members to keep cargo from trying to
  # load its (absent) manifest.
  postPatch = ''
    sed -i \
      -e 's|"subprojects/hydra-queue-runner", ||' \
      -e 's|"subprojects/hydra-drv-daemon", ||' \
      -e '/^[[:space:]]*"subprojects\/hydra-queue-runner",[[:space:]]*$/d' \
      -e '/^[[:space:]]*"subprojects\/hydra-drv-daemon",[[:space:]]*$/d' \
      Cargo.toml
  '';

  buildAndTestSubdir = "subprojects/hydra-builder";
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

  meta.description = "Hydra builder (Rust)";
}

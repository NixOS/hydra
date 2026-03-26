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
      "harmonia-store-core-0.0.0-alpha.0" = "sha256-g7JJGrjWnnzBtxtxLaqL/wKehPBZAHh8C7U7ALYW6o0=";
    };
  };

  # Drop the other Rust binary crates from the workspace; their sources
  # are excluded from the fileset above, so cargo would otherwise fail
  # trying to load their (absent) manifests.
  postPatch = ''
    sed -i '/hydra-builder/!{/"subprojects\/hydra-/d;}' Cargo.toml
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

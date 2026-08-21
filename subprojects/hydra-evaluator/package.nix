{
  lib,
  version,

  rustPlatform,

  protobuf,
  pkg-config,
  rust-jemalloc-sys,
}:

rustPlatform.buildRustPackage {
  pname = "hydra-evaluator";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../.cargo
      ../../.sqlx
      ../../subprojects/hydra-evaluator/Cargo.toml
      ../../subprojects/hydra-evaluator/src
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
    sed -i '/hydra-evaluator/!{/"subprojects\/hydra-/d;}' Cargo.toml
  '';

  buildAndTestSubdir = "subprojects/hydra-evaluator";

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

  meta.description = "Hydra evaluator (Rust)";
}

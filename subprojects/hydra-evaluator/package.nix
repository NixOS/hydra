{
  lib,
  version,

  rustPlatform,

  nixComponents,
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
    outputHashes = {
      "harmonia-store-core-0.0.0-alpha.0" = "sha256-BbxquEFuDYobtCEIEiIsf1D0A1CK/szCwkgCyzSCWMY=";
    };
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
    nixComponents.nix-main
    protobuf
    rust-jemalloc-sys
  ];

  # FIXME: get these passing in a prod build
  doCheck = false;

  meta.description = "Hydra evaluator (Rust)";
}

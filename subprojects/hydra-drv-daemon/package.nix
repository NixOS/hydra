{
  lib,
  version,

  rustPlatform,

  pkg-config,
}:

rustPlatform.buildRustPackage {
  pname = "hydra-drv-daemon";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../Cargo.toml
      ../../Cargo.lock
      ../../.cargo
      ../../.sqlx
      ../../subprojects/hydra-drv-daemon/Cargo.toml
      ../../subprojects/hydra-drv-daemon/src
      ../../subprojects/crates
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
    sed -i '/hydra-drv-daemon/!{/"subprojects\/hydra-/d;}' Cargo.toml
  '';

  buildAndTestSubdir = "subprojects/hydra-drv-daemon";

  nativeBuildInputs = [
    pkg-config
  ];

  doCheck = false;

  meta.description = "Hydra drv-daemon: spawn ad-hoc Hydra builds via the nix daemon protocol";
}

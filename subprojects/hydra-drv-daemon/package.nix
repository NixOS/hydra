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
    outputHashes = {
      "harmonia-store-core-0.0.0-alpha.0" = "sha256-EwOfW4esHMOaxoxgrguLJYLPQXoFjzOljR2+x+mmo3k=";
    };
  };

  # Strip workspace siblings that aren't included in the source fileset
  # so cargo doesn't try to load their manifests.
  postPatch = ''
    sed -i \
      -e 's|"subprojects/hydra-queue-runner", ||' \
      -e 's|"subprojects/hydra-builder", ||' \
      -e '/^[[:space:]]*"subprojects\/hydra-queue-runner",[[:space:]]*$/d' \
      -e '/^[[:space:]]*"subprojects\/hydra-builder",[[:space:]]*$/d' \
      Cargo.toml
  '';

  buildAndTestSubdir = "subprojects/hydra-drv-daemon";

  nativeBuildInputs = [
    pkg-config
  ];

  doCheck = false;

  meta.description = "Hydra drv-daemon: spawn ad-hoc Hydra builds via the nix daemon protocol";
}

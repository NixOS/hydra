# One dependency build (cargoArtifacts) shared by every workspace crate, so
# CI only recompiles hydra's own crates.
{
  lib,
  craneLib,
  protobuf,
  pkg-config,
  rust-jemalloc-sys,
}:
let
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../.cargo
      ../.sqlx
      ../subprojects/hydra-queue-runner/Cargo.toml
      ../subprojects/hydra-queue-runner/src
      ../subprojects/hydra-queue-runner/examples
      ../subprojects/hydra-builder/Cargo.toml
      ../subprojects/hydra-builder/src
      ../subprojects/crates
      # For unit tests which want to spin up a fresh database
      ../subprojects/hydra/sql/hydra.sql
      ../subprojects/proto
    ];
  };

  commonArgs = {
    inherit src;
    pname = "hydra-rust-workspace";
    version = "0.0.0";
    strictDeps = true;

    nativeBuildInputs = [
      pkg-config
      protobuf
    ];

    buildInputs = [
      rust-jemalloc-sys
    ];
  };

  cargoArtifacts = craneLib.buildDepsOnly commonArgs;
in
{
  inherit cargoArtifacts;

  mkCrate =
    {
      pname,
      version,
      features ? [ ],
      meta,
    }:
    craneLib.buildPackage (
      commonArgs
      // {
        inherit
          pname
          version
          meta
          cargoArtifacts
          ;
        cargoExtraArgs = lib.concatStringsSep " " (
          [ "--package ${pname}" ]
          ++ lib.optional (features != [ ]) "--features ${lib.concatStringsSep "," features}"
        );
        # FIXME: get these passing in a prod build
        doCheck = false;
      }
    );
}

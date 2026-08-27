# One dependency build (cargoArtifacts) shared by every workspace crate, so
# CI only recompiles hydra's own crates.
{
  lib,
  runCommand,
  version,
  craneLib,
  protobuf,
  pkg-config,
  rust-jemalloc-sys,
  # Features are a property of the workspace, not of an individual crate: cargo
  # resolves them once for the whole `--workspace` build, so a per-crate knob
  # would just fork the build. Override this on the scope to move every crate
  # at once.
  withOtel ? false,
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
      ../subprojects/hydra-evaluator/Cargo.toml
      ../subprojects/hydra-evaluator/src
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

  # A virtual manifest rejects a bare `--features`, so name the members. Every
  # member that has the feature gets it: enabling it for only some of them
  # would fork the workspace build.
  features = lib.optionals withOtel [
    "hydra-builder/otel"
    "hydra-queue-runner/otel"
  ];

  # `cargoArtifacts` is a whole-workspace `buildDepsOnly`, so its dependencies
  # are compiled with the features unified across every member. Building a
  # single member with `--package` resolves a *narrower* feature set
  # (`resolver = "2"` does not unify across members), so the fingerprints do not
  # match and cargo recompiles the entire dependency tree. Build `--workspace`
  # here instead, matching the deps build exactly, and let each crate pick its
  # binary out of the result.
  workspace = craneLib.buildPackage (
    commonArgs
    // {
      inherit version cargoArtifacts;
      cargoExtraArgs = lib.concatStringsSep " " (
        [ "--workspace" ]
        ++ lib.optional (features != [ ]) "--features ${lib.concatStringsSep "," features}"
      );
      # FIXME: get these passing in a prod build
      doCheck = false;
    }
  );
  # Each crate is just its binary lifted out of the shared build, so there is
  # nothing crate-specific left to keep in a `package.nix` of its own.
  mkCrate =
    {
      pname,
      meta,
    }:
    runCommand "${pname}-${version}"
      {
        meta = {
          mainProgram = pname;
        }
        // meta;
      }
      ''
        mkdir -p "$out/bin"
        cp "${workspace}/bin/${pname}" "$out/bin/${pname}"
      '';
in
{
  inherit cargoArtifacts workspace;

  hydra-builder = mkCrate {
    pname = "hydra-builder";
    meta.description = "Hydra builder (Rust)";
  };

  hydra-queue-runner = mkCrate {
    pname = "hydra-queue-runner";
    meta.description = "Hydra queue runner (Rust)";
  };

  hydra-evaluator = mkCrate {
    pname = "hydra-evaluator";
    meta.description = "Hydra evaluator (Rust)";
  };
}

{ lib
, version

, rustPlatform

, nixComponents
, protobuf
, pkg-config
, rust-jemalloc-sys
}:

rustPlatform.buildRustPackage {
  pname = "hydra-rust";
  inherit version;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../Cargo.toml
      ../Cargo.lock
      ../.cargo
      ../.sqlx
      ../subprojects/hydra-queue-runner/Cargo.toml
      ../subprojects/hydra-queue-runner/build.rs
      ../subprojects/hydra-queue-runner/src
      ../subprojects/hydra-queue-runner/examples
      ../subprojects/hydra-builder/Cargo.toml
      ../subprojects/hydra-builder/build.rs
      ../subprojects/hydra-builder/src
      ../subprojects/hydra-evaluator/Cargo.toml
      ../subprojects/hydra-evaluator/src
      ../subprojects/crates
      ../subprojects/proto
    ];
  };

  cargoLock = {
    lockFile = ../Cargo.lock;
    outputHashes = {
      "harmonia-store-core-0.0.0-alpha.0" = "sha256-FDL2xxAFOYw21VhGYake2fFC9S7jK5kBSM4OfU12VmQ=";
    };
  };

  outputs = [
    # TODO: build crates separately so each is its own derivation, or at the
    # very least drop "out"
    "out"
    "queue_runner"
    "builder"
    "evaluator"
  ];

  nativeBuildInputs = [
    pkg-config
    protobuf
  ];

  buildInputs = [
    nixComponents.nix-main
    protobuf
    rust-jemalloc-sys
  ];

  postInstall = ''
    mkdir -p $queue_runner/bin $builder/bin $evaluator/bin
    mv $out/bin/hydra-queue-runner $queue_runner/bin/
    mv $out/bin/hydra-builder $builder/bin/
    mv $out/bin/hydra-evaluator $evaluator/bin/
    ln -s $queue_runner/bin/hydra-queue-runner $out/bin/hydra-queue-runner
    ln -s $builder/bin/hydra-builder $out/bin/hydra-builder
    ln -s $evaluator/bin/hydra-evaluator $out/bin/hydra-evaluator
  '';

  # FIXME: get these passing in a prod build
  doCheck = false;

  meta.description = "Hydra Rust binaries (queue runner, builder, evaluator)";
}

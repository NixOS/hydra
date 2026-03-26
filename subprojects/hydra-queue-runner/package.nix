{ lib
, version

, rustPlatform

, nixComponents
, protobuf
, pkg-config
, rust-jemalloc-sys
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
      ../../subprojects/hydra-builder/Cargo.toml
      ../../subprojects/hydra-builder/build.rs
      ../../subprojects/hydra-builder/src
      ../../subprojects/crates
      ../../subprojects/proto
    ];
  };

  cargoLock = {
    lockFile = ../../Cargo.lock;
    outputHashes = {
      "nix-diff-0.1.0" = "sha256-heUqcAnGmMogyVXskXc4FMORb8ZaK6vUX+mMOpbfSUw=";
      "harmonia-store-core-0.0.0-alpha.0" = "sha256-w0YRYNvq5dY5FBa73A66v4E5L0xmNuAfDNzsTIyW8uk=";
      "nix-bindings-store-0.2.1" = "sha256-8WRgfkfnPV3FeaY9A8TisKCRsOaEso/Z8GE3jivfGsA=";
      "nix-bindings-util-0.2.1" = "sha256-8WRgfkfnPV3FeaY9A8TisKCRsOaEso/Z8GE3jivfGsA=";
    };
  };

  nativeBuildInputs = [
    pkg-config
    protobuf
    rustPlatform.bindgenHook
  ];

  buildInputs = [
    nixComponents.nix-main
    nixComponents.nix-store-c
    nixComponents.nix-util-c
    protobuf
    rust-jemalloc-sys
  ];

  # FIXME: get these passing in a prod build
  doCheck = false;

  meta.description = "Hydra queue runner and builder (Rust)";
}

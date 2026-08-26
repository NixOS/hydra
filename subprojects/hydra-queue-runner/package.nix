{
  lib,
  version,
  rustWorkspace,
  withOtel ? false,
}:

rustWorkspace.mkCrate {
  pname = "hydra-queue-runner";
  inherit version;
  features = lib.optional withOtel "otel";
  meta.description = "Hydra queue runner (Rust)";
}

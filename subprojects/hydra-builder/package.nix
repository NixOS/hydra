{
  lib,
  version,
  rustWorkspace,
  withOtel ? false,
}:

rustWorkspace.mkCrate {
  pname = "hydra-builder";
  inherit version;
  features = lib.optional withOtel "otel";
  meta.description = "Hydra builder (Rust)";
}

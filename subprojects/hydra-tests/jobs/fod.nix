with import ./config.nix;
{
  # A flat-hash fixed-output derivation.
  # sha256 of "hello" (no newline).
  fod = derivation {
    name = "test-fod";
    system = builtins.currentSystem;
    builder = ./fod-builder.sh;
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
  };
}

{ variant }:
with import ./config.nix;
{
  # `variant` changes the derivation but not the fixed output path, so
  # evaluating again with another variant repoints the existing build.
  fod = derivation {
    name = "test-fod-repoint";
    system = builtins.currentSystem;
    builder = ./fod-builder.sh;
    inherit variant;
    outputHashMode = "flat";
    outputHashAlgo = "sha256";
    outputHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";
  };
}

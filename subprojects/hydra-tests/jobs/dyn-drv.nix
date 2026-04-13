# Adapted from https://github.com/NixOS/nix/blob/14ffc1787182b8702910788aea02bd5804afb32e/tests/functional/dyn-drv/text-hashed-output.nix
#
# A derivation produces a .drv file as its output; another derivation depends
# on building that dynamically-produced .drv and using its output.
let
  cfg = import ./config.nix;
in
rec {
  # A simple CA derivation that produces $out/hello.
  hello = cfg.mkContentAddressedDerivation {
    name = "hello";
    builder = ./empty-dir-builder.sh;
  };

  # A CA derivation whose output IS a .drv file.
  # Copies hello's .drv path to $out using text hashing so the output
  # is a single flat file rather than a directory.
  producingDrv = cfg.mkDerivation {
    name = "hello.drv";
    builder = "/bin/sh";
    args = [
      "-c"
      ''cp ${builtins.unsafeDiscardOutputDependency hello.drvPath} $out''
    ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
  };

  # The actual dynamic derivation consumer: depends on the output of the
  # .drv file that producingDrv produces. Nix must:
  #   1. Build producingDrv (get the .drv file)
  #   2. Discover the .drv at its output
  #   3. Build THAT .drv
  #   4. Use its output here
  wrapper = cfg.mkContentAddressedDerivation {
    name = "dyn-drv-wrapper";
    builder = "/bin/sh";
    args = [
      "-c"
      ''cp -r ${builtins.outputOf producingDrv.outPath "out"} $out''
    ];
  };
}

# A derivation whose output is itself a `.drv`, so that the derivation
# it describes can be asked for as a dynamic derived path, `producer^out^out`.
# Adapted from ../dyn-drv.nix, which exercises the same thing as an
# *input* of a jobset build; here it is the top-level request.
let
  cfg = import ../config.nix;

  hello = cfg.mkContentAddressedDerivation {
    name = "hello";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        mkdir -p "$out"
        echo "greeting: $GREETING" > $out/result
      ''
    ];
    GREETING = "XXXX derivation";
  };
in
{
  # Copies hello's .drv, rewriting X to Y, so the derivation it produces
  # differs from any the evaluator has seen.
  producer = cfg.mkDerivation {
    name = "hello.drv";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        drv=${builtins.unsafeDiscardOutputDependency hello.drvPath}
        tr X Y < "$drv" > "$out"
      ''
    ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
  };
}

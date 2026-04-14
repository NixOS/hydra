# Adapted from https://github.com/NixOS/nix/blob/14ffc1787182b8702910788aea02bd5804afb32e/tests/functional/dyn-drv/text-hashed-output.nix
#
# A derivation produces a .drv file as its output; another derivation depends
# on building that dynamically-produced .drv and using its output.
let
  cfg = import ./config.nix;

  # A CA derivation that writes content based on the GREETING env var.
  # The GREETING contains 'X' which producingDrv rewrites to 'Y' via
  # tr at build time, so the dynamically-produced .drv differs from
  # the statically-known one.
  hello = cfg.mkContentAddressedDerivation {
    name = "hello";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        mkdir -p "$out"
        echo "greeting while builder: $GREETING" >&2
        echo "saving greeting to output: $GREETING" > $out/result
      ''
    ];
    GREETING = "XXXX derivation";
  };

  # A CA derivation whose output IS a .drv file.
  # Copies hello's .drv then rewrites X→Y so the dynamic derivation
  # builds with GREETING="YYYY derivation" instead of "XXXX derivation".
  # tr is in coreutils so it's available on PATH.
  producingDrv = cfg.mkDerivation {
    name = "hello.drv";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        drv=${builtins.unsafeDiscardOutputDependency hello.drvPath}
        echo rewriting "$drv" >&2
        tr X Y < "$drv" > "$out"
      ''
    ];
    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
  };

in
{
  # The actual dynamic derivation consumer: depends on the output of the
  # .drv file that producingDrv produces. Nix must:
  #   1. Build producingDrv (get the .drv file)
  #   2. Discover the .drv at its output
  #   3. Build THAT .drv (which runs dyn-drv-builder.sh with GREETING="YYYY derivation")
  #   4. Use its output here
  wrapper = cfg.mkContentAddressedDerivation {
    name = "dyn-drv-wrapper";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        result=${builtins.outputOf producingDrv.outPath "out"}
        # Verify the dynamically-built derivation used the rewritten GREETING
        case "$(cat "$result/result")" in
          *YYYY*) ;;
          *) echo "expected YYYY in result" >&2; exit 1 ;;
        esac
        cp -r "$result" $out
      ''
    ];
  };
}

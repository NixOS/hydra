# Adapted from https://github.com/NixOS/nix/blob/master/tests/functional/dyn-drv/non-trivial.nix
#
# A single derivation uses recursive-nix to dynamically create a DAG of
# inner derivations (a through e) via `nix derivation add`, then outputs
# the final .drv path.  A wrapper depends on building that
# dynamically-produced .drv and using its output via builtins.outputOf.
let
  cfg = import ./config.nix;

  makeDerivations = cfg.mkDerivation {
    name = "make-derivations.drv";

    requiredSystemFeatures = [ "recursive-nix" ];

    builder = "/bin/sh";
    args = [
      "-c"
      ''
        set -e
        set -u

        PATH=${cfg.nixBinDir}:$PATH

        export NIX_CONFIG='extra-experimental-features = nix-command ca-derivations dynamic-derivations'

        declare -A deps=(
          [a]=""
          [b]="a"
          [c]="a"
          [d]="b c"
          [e]="b c d"
        )

        # Cannot just literally include this, or Nix will think it is the
        # *outer* derivation that's trying to refer to itself, and
        # substitute the string too soon.
        placeholder=$(nix eval --raw --expr 'builtins.placeholder "out"')

        declare -A drvs=()
        for word in a b c d e; do
          inputDrvs=""
          for dep in ''${deps[$word]}; do
            if [[ "$inputDrvs" != "" ]]; then
              inputDrvs+=","
            fi
            read -r -d "" line <<EOF || true
            "''${drvs[$dep]}": {
              "outputs": ["out"],
              "dynamicOutputs": {}
            }
        EOF
            inputDrvs+="$line"
          done
          read -r -d "" json <<EOF || true
          {
            "args": ["-c", "set -xeu; echo \"word env vav $word is \$$word\" >> \"\$out\""],
            "builder": "/bin/sh",
            "env": {
              "out": "$placeholder",
              "$word": "hello, from $word!",
              "PATH": ${builtins.toJSON cfg.path}
            },
            "inputs": {
              "drvs": {
                $inputDrvs
              },
              "srcs": []
            },
            "name": "build-$word",
            "outputs": {
              "out": {
                "method": "nar",
                "hashAlgo": "sha256"
              }
            },
            "system": "${builtins.currentSystem}",
            "version": 4
          }
        EOF
          drvPath=$(echo "$json" | nix derivation add)
          storeDir=$(dirname "$drvPath")
          drvs[$word]="$(basename "$drvPath")"
        done
        cp "''${storeDir}/''${drvs[e]}" $out
      ''
    ];

    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";
  };

in
{
  # The dynamic derivation consumer: depends on the output of the .drv
  # file that makeDerivations produces.  Nix must:
  #   1. Build makeDerivations (creates derivations a-e, outputs e's .drv)
  #   2. Discover the .drv at its output
  #   3. Build that .drv (which transitively builds a, b, c, d, e)
  #   4. Use its output here
  wrapper = cfg.mkContentAddressedDerivation {
    name = "dyn-drv-non-trivial-wrapper";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        result=${builtins.outputOf makeDerivations.outPath "out"}
        cat "$result"
        cp -r "$result" $out
      ''
    ];
  };
}

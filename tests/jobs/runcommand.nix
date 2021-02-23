with import ./config.nix;
{
  metrics = mkDerivation {
    name = "my-build-product";
    builder = "/bin/sh";
    outputs = [ "out" "bin" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          echo "$PATH"

          mkdir $bin
          echo "foo" > $bin/bar

          metrics=$out/nix-support/hydra-metrics
          mkdir -p "$(dirname "$metrics")"
          echo "lineCoverage 18 %" >> "$metrics"
          echo "maxResident 27 KiB" >> "$metrics"
        ''
      )
    ];
  };
}

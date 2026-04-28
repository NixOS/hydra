# Plain input-addressed derivation submitted directly to hydra-drv-daemon
# via `nix-store --realise`, without any Hydra jobset / evaluator round-trip.
let
  cfg = import ../config.nix;
in
{
  hello = cfg.mkDerivation {
    name = "hello-adhoc";
    builder = "/bin/sh";
    args = [
      "-c"
      ''
        mkdir -p $out
        echo "hello from drv-daemon" > $out/result
      ''
    ];
  };
}

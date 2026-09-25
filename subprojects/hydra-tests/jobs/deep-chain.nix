# A linear chain of derivations whose leaf fails. The queue runner has to walk
# the whole chain when loading the build, so this exercises deep dependency
# graphs without having to actually build every link.
with import ./config.nix;
let
  depth = 200;
  leaf = mkDerivation {
    name = "deep-chain-0";
    builder = ./fail.sh;
  };
  link =
    n: prev:
    mkDerivation {
      name = "deep-chain-${toString n}";
      builder = ./empty-dir-builder.sh;
      inherit prev;
    };
in
{
  deep_chain = builtins.foldl' (prev: n: link n prev) leaf (builtins.genList (n: n + 1) depth);
}

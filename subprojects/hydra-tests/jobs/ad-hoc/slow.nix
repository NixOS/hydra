# Several distinct derivations that each take a few seconds, so that
# more than one ad hoc build can be in flight at once.
let
  cfg = import ../config.nix;
  slow =
    tag:
    cfg.mkDerivation {
      name = "slow-adhoc-${tag}";
      builder = "/bin/sh";
      args = [
        "-c"
        ''
          sleep 5
          mkdir -p $out
          echo "${tag}" > $out/result
        ''
      ];
    };
in
{
  a = slow "a";
  b = slow "b";
  c = slow "c";
}

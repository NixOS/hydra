let
  cfg = import ./config.nix;
in
rec {
  # Early-cutoff test: two upstream derivations that differ in a dummy
  # attribute but produce the same output (an empty directory).  Because
  # they are content-addressed, they resolve to the same output path.
  # Both downstreams depend on a different upstream, but since the
  # resolved input is identical, the second downstream should be cached.
  earlyCutoffUpstream1 = cfg.mkContentAddressedDerivation {
    name = "early-cutoff-upstream";
    builder = ./empty-dir-builder.sh;
    dummy = "1";
  };

  earlyCutoffUpstream2 = cfg.mkContentAddressedDerivation {
    name = "early-cutoff-upstream";
    builder = ./empty-dir-builder.sh;
    dummy = "2";
  };

  earlyCutoffDownstream1 = cfg.mkContentAddressedDerivation {
    name = "early-cutoff-downstream";
    builder = ./dir-with-file-builder.sh;
    FOO = earlyCutoffUpstream1;
  };

  earlyCutoffDownstream2 = cfg.mkContentAddressedDerivation {
    name = "early-cutoff-downstream";
    builder = ./dir-with-file-builder.sh;
    FOO = earlyCutoffUpstream2;
  };
}

let
  cfg = import ./config.nix;
in
rec {
  empty_dir = cfg.mkContentAddressedDerivation {
    name = "empty-dir";
    builder = ./empty-dir-builder.sh;
  };

  fails = cfg.mkContentAddressedDerivation {
    name = "fails";
    builder = ./fail.sh;
  };

  succeed_with_failed = cfg.mkContentAddressedDerivation {
    name = "succeed-with-failed";
    builder = ./succeed-with-failed.sh;
  };

  caDependingOnCA = cfg.mkContentAddressedDerivation {
    name = "ca-depending-on-ca";
    builder = ./dir-with-file-builder.sh;
    FOO = empty_dir;
  };

  caDependingOnCADependingOnCA = cfg.mkContentAddressedDerivation {
    name = "ca-depending-on-ca-depending-on-ca";
    builder = ./dir-with-file-builder.sh;
    FOO = caDependingOnCA;
  };

  caDependingOnFailingCA = cfg.mkContentAddressedDerivation {
    name = "ca-depending-on-failing-ca";
    builder = ./dir-with-file-builder.sh;
    FOO = fails;
  };

  nonCaDependingOnCA = cfg.mkDerivation {
    name = "non-ca-depending-on-ca";
    builder = ./dir-with-file-builder.sh;
    FOO = empty_dir;
  };

  multiOutput = cfg.mkContentAddressedDerivation {
    name = "multi-output";
    builder = ./multi-out.sh;
    outputs = [
      "out"
      "bin"
      "lib"
    ];
  };

  caRewrite = cfg.mkContentAddressedDerivation {
    name = "ca-rewrite";
    builder = ./ca-rewrite.sh;
  };

  caRewriteMulti = cfg.mkContentAddressedDerivation {
    name = "ca-rewrite-multi";
    builder = ./ca-rewrite-multi.sh;
    outputs = [
      "out"
      "lib"
    ];
  };

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

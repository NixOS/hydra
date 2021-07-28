let cfg =  import ./config.nix; in
rec {
  empty_dir =
    cfg.mkContentAddressedDerivation {
      name = "empty-dir";
      builder = ./empty-dir-builder.sh;
    };

  fails =
    cfg.mkContentAddressedDerivation {
      name = "fails";
      builder = ./fail.sh;
    };

  succeed_with_failed =
    cfg.mkContentAddressedDerivation {
      name = "succeed-with-failed";
      builder = ./succeed-with-failed.sh;
    };

  nonCaDependingOnCA =
    cfg.mkDerivation {
      name = "non-ca-depending-on-ca";
      builder = ./empty-dir-builder.sh;
      FOO = empty_dir;
    };
}


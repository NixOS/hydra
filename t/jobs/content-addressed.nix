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

  caDependingOnCA =
    cfg.mkContentAddressedDerivation {
      name = "ca-depending-on-ca";
      builder = ./dir-with-file-builder.sh;
      FOO = empty_dir;
    };

  nonCaDependingOnCA =
    cfg.mkDerivation {
      name = "non-ca-depending-on-ca";
      builder = ./dir-with-file-builder.sh;
      FOO = empty_dir;
    };
}


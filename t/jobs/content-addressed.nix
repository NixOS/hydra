let cfg =  import ./config.nix; in
{
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
}


let cfg =  import ./config.nix; in
let
  mkDerivation = args: cfg.mkDerivation ({
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  } // args);
in
{
  empty_dir =
    mkDerivation {
      name = "empty-dir";
      builder = ./empty-dir-builder.sh;
    };

  fails =
    mkDerivation {
      name = "fails";
      builder = ./fail.sh;
    };

  succeed_with_failed =
    mkDerivation {
      name = "succeed-with-failed";
      builder = ./succeed-with-failed.sh;
    };
}


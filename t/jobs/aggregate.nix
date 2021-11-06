with import ./config.nix;
{
  a =
    mkDerivation {
      name = "empty-dir-a";
      builder = ./empty-dir-builder.sh;
    };

  b =
    mkDerivation {
      name = "empty-dir-b";
      builder = ./empty-dir-builder.sh;
    };

  aggregate =
    mkDerivation {
      name = "aggregate";
      builder = ./empty-dir-builder.sh; # doesn't matter, just needs to pass a build

      _hydraAggregate = true;
      constituents = [
        "a"
        "b"
      ];
    };
}

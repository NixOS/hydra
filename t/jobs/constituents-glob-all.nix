with import ./config.nix;
{
  packages.constituentA = mkDerivation {
    name = "empty-dir-A";
    builder = ./empty-dir-builder.sh;
  };

  packages.constituentB = mkDerivation {
    name = "empty-dir-B";
    builder = ./empty-dir-builder.sh;
  };

  ok_aggregate = mkDerivation {
    name = "direct_aggregate";
    _hydraAggregate = true;
    _hydraGlobConstituents = true;
    constituents = [
      "*"
    ];
    builder = ./empty-dir-builder.sh;
  };
}

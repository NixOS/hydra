with import ./config.nix;
{
  packages.constituentA = mkDerivation {
    name = "empty-dir-A";
    builder = ./empty-dir-builder.sh;
    _hydraAggregate = true;
    _hydraGlobConstituents = true;
    constituents = [ "*_aggregate" ];
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
      "packages.*"
    ];
    builder = ./empty-dir-builder.sh;
  };

  indirect_aggregate = mkDerivation {
    name = "indirect_aggregate";
    _hydraAggregate = true;
    constituents = [
      "ok_aggregate"
    ];
    builder = ./empty-dir-builder.sh;
  };
}

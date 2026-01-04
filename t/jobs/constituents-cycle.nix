with import ./config.nix;
{
  ok_aggregate = mkDerivation {
    name = "direct_aggregate";
    _hydraAggregate = true;
    _hydraGlobConstituents = true;
    constituents = [
      "indirect_aggregate"
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

with import ./config.nix;
rec {
  constituentA = mkDerivation {
    name = "empty-dir-A";
    builder = ./empty-dir-builder.sh;
  };

  constituentB = mkDerivation {
    name = "empty-dir-B";
    builder = ./empty-dir-builder.sh;
  };

  direct_aggregate = mkDerivation {
    name = "direct_aggregate";
    _hydraAggregate = true;
    constituents = [
      constituentA
    ];
    builder = ./empty-dir-builder.sh;
  };

  indirect_aggregate = mkDerivation {
    name = "indirect_aggregate";
    _hydraAggregate = true;
    constituents = [
      "constituentA"
    ];
    builder = ./empty-dir-builder.sh;
  };

  mixed_aggregate = mkDerivation {
    name = "mixed_aggregate";
    _hydraAggregate = true;
    constituents = [
      "constituentA"
      constituentB
    ];
    builder = ./empty-dir-builder.sh;
  };
}

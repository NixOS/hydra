with import ./config.nix;
rec {
  constituentA = null;

  constituentB = mkDerivation {
    name = "empty-dir-B";
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

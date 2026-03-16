with import ./config.nix;
{
  non_match_aggregate = mkDerivation {
    name = "mixed_aggregate";
    _hydraAggregate = true;
    _hydraGlobConstituents = true;
    constituents = [
      "tests.*"
    ];
    builder = ./empty-dir-builder.sh;
  };

  # Without a second job no jobset is attempted to be created
  # (the only job would be broken)
  # and thus the constituent validation is never reached.
  dummy = mkDerivation {
    name = "dummy";
    builder = ./empty-dir-builder.sh;
  };
}

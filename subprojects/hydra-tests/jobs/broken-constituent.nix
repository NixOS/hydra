with import ./config.nix;
{
  broken = mkDerivation {
    name = "broken";
    _hydraAggregate = true;
    constituents = [
      "does-not-exist"
      "does-not-evaluate"
    ];
    builder = ./fail.sh;
  };

  # does-not-exist doesn't exist.

  does-not-evaluate = assert false; {};
}

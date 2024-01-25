with import ./config.nix;
{
  fixed_output = mkDerivation {
    name = "fixed-output";
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-INobAY6wP6WMUdr0Wr2CsEpdJbu46nX55BYSDmvSkas=";
    builder = ./name-builder.sh;
  };

  fixed_output_bad_hash = mkDerivation {
    name = "wrong-hash";
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    outputHash = "sha256-ANobAY6wP6WMUdr0Wr2CsEpdJbu46nX55BYSDmvSkas=";
    builder = ./name-builder.sh;
  };
}


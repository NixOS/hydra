with import ./config.nix;
{
  success = mkDerivation {
    name = "logging-success";
    builder = ./logging-success.sh;
  };

  failure = mkDerivation {
    name = "logging-failure";
    builder = ./logging-failure.sh;
  };
}

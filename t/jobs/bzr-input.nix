with import ./config.nix;
{ src }:
{
  copy =
    mkDerivation {
      name = "bzr-input";
      builder = ./scm-builder.sh;
      inherit src;
    };
}

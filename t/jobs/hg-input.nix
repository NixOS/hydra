with import ./config.nix;
{ src }:
{
  copy =
    mkDerivation {
      name = "hg-input";
      builder = ./scm-builder.sh;
      inherit src;
    };
}

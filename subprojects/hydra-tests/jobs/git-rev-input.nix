with import ./config.nix;
{ src }:
{
  copy =
    mkDerivation {
      name = "git-rev-input";
      builder = ./scm-builder.sh;
      inherit src;
    };
}

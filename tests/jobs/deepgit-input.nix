with import ./config.nix;
{ src }:
{  
  copy = 
    mkDerivation {
      name = "git-input";
      builder = ./scm-builder.sh;
      inherit src;
    };
}

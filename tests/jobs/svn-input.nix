with import ./config.nix;
{ src }:
{  
  copy = 
    mkDerivation {
      name = "svn-input";
      builder = ./scm-builder.sh;
      inherit src;
    };
}

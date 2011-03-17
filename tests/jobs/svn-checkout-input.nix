with import ./config.nix;
{ src }:
{  
  copy = 
    mkDerivation {
      name = "bzr-checkout-input";
      builder = ./scm-builder.sh;
      inherit src;
    };
}

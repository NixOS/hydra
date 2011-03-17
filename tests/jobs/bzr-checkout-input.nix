{ src }:
{  
  copy = 
    derivation {
      name = "bzr-checkout-input";
      system = builtins.currentSystem;
      builder = ./scm-builder.sh;
    };
}

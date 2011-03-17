{ src }:
{  
  copy = 
    derivation {
      name = "bzr-input";
      system = builtins.currentSystem;
      builder = ./scm-builder.sh;
    };
}

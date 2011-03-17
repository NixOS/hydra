{ src }:
{  
  copy = 
    derivation {
      name = "hg-input";
      system = builtins.currentSystem;
      builder = ./scm-builder.sh;
    };
}

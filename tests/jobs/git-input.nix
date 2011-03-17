{ src }:
{  
  copy = 
    derivation {
      name = "git-input";
      system = builtins.currentSystem;
      builder = ./scm-builder.sh;
    };
}

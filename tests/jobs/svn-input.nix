{ src }:
{  
  copy = 
    derivation {
      name = "svn-input";
      system = builtins.currentSystem;
      builder = ./scm-builder.sh;
    };
}

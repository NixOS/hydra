{ input }:
{  
  empty_dir = 
    derivation {
      name = "empty-dir";
      system = builtins.currentSystem;
      builder = ./empty-dir-builder.sh;
    };

  fails = 
    derivation {
      name = "fails";
      system = builtins.currentSystem;
      builder = ./fail.sh;
    };

  succeed_with_failed = 
    derivation {
      name = "succeed-with-failed";
      system = builtins.currentSystem;
      builder = ./succeed-with-failed.sh;
    };
}

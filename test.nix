let

  pkgs = import (builtins.getEnv "NIXPKGS_ALL") {};
  
  pkgs64 = import (builtins.getEnv "NIXPKGS_ALL") {system = "x86_64-linux";};

in

{

  job1 = pkgs.hello;

  job1_64 = pkgs64.hello;

  job2 = pkgs.aterm;

}

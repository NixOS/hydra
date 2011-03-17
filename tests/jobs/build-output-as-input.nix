with import ./config.nix;
let
  jobs = {
    build1 =
      mkDerivation {
        name = "build1";
        builder = ./empty-dir-builder.sh;
      };

    build2 = 
      {build1 ? jobs.build1 }:
      mkDerivation {
        name = "build2";
        builder = ./empty-dir-builder.sh;
        inherit build1;
      };
  };
in jobs

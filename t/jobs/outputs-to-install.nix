with import ./config.nix;
{
  example = (mkDerivation {
    name = "example";
    builder = "/bin/sh";
    outputs = [ "out" "installed" "notinstalled" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          mkdir $out $installed $notinstalled
        ''
      )
    ];
  }) // {
    meta = {
      outputsToInstall = [ "out" "installed" ];
    };
  };
}

{ flakePackages }:
{
  builder =
    { pkgs, lib, ... }:
    {
      _file = ./default.nix;
      imports = [ ./builder-module.nix ];
      services.hydra-queue-builder-dev.package =
        lib.mkDefault
          flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra-builder;
    };
}

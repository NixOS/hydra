with import ./config.nix;
{
  canbesubstituted =
    mkDerivation {
      name = "can-be-substituted";
      builder = ./empty-dir-builder.sh;
    };
    
  unsubstitutable =
    mkDerivation {
      name = "unsubstitutable";
      builder = ./empty-dir-builder.sh;
    };
}

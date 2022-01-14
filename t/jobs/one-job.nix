with import ./config.nix;
{
  one_job =
    mkDerivation {
      name = "empty-dir";
      builder = ./empty-dir-builder.sh;
    };
}

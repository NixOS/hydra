with import ./config.nix;
{
  requireExperimentalFeatures =
    mkDerivation {
      name = "empty-dir";
      builder = ./empty-dir-builder.sh;
      requiredSystemFeatures = [ "test-system-feature" ];
    };
}

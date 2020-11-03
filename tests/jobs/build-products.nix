with import ./config.nix;
{
  simple = mkDerivation {
    name = "build-product-simple";
    builder = ./build-product-simple.sh;
  };

  with_spaces = mkDerivation {
    name = "build-product-with-spaces";
    builder = ./build-product-with-spaces.sh;
  };

  multiple_store_paths = mkDerivation {
    not_out = builtins.toFile "test" "this is a test";
    name = "build-product-multiple-store-paths";
    builder = ./build-product-multiple.sh;
  };
}

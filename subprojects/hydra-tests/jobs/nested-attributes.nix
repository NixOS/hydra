with import ./config.nix;
rec {
  # Given a jobset containing a package set named X with an interior member Y,
  # expose the interior member Y with the name X-Y. This is to exercise a bug
  # in the NixExprs view's generated Nix expression which flattens the
  # package set namespace from `X.Y` to `X-Y`. If the bug is present, the
  # resulting expression incorrectly renders two `X-Y` packages.
  packageset = {
    recurseForDerivations = true;
    deeper = {
      recurseForDerivations = true;
      deeper = {
        recurseForDerivations = true;

        nested = mkDerivation {
          name = "much-too-deep";
          builder = ./empty-dir-builder.sh;
        };
      };
    };

    nested = mkDerivation {
      name = "actually-nested";
      builder = ./empty-dir-builder.sh;
    };

    nested2 = mkDerivation {
      name = "actually-nested2";
      builder = ./empty-dir-builder.sh;
    };
  };
  packageset-nested = mkDerivation {
    name = "actually-top-level";
    builder = ./empty-dir-builder.sh;
  };
}

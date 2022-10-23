with import ./config.nix;
{
  simple =
    mkDerivation {
      name = "simple";
      builder = ./empty-dir-builder.sh;
      meta.maintainers = [
        { github = "foo"; email = "foo@example.org"; }
        { github = "bar"; email = "bar@example.org"; }
      ];
      meta.outPath = "${placeholder "out"}";
    };

  old_maintainer_style =
    mkDerivation {
      name = "old_maintainer_style";
      builder = ./fail.sh;
      meta.maintainers = [
        "foo@example.org"
        "baz@example.org"
      ];
      meta.outPath = "${placeholder "out"}";
    };

  mixed =
    mkDerivation {
      name = "mixed";
      builder = ./empty-dir-builder.sh;
      meta.maintainers = [
        { github = "abc"; email = "abc@example.org"; }
        "baz@example.org"
      ];
      meta.outPath = "${placeholder "out"}";
    };

  none =
    mkDerivation {
      name = "none";
      builder = ./empty-dir-builder.sh;
    };
}

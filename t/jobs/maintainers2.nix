with import ./config.nix;
{
  simple =
    mkDerivation {
      name = "simple";
      builder = ./empty-dir-builder.sh;
      meta.maintainers = [
        { github = "foo_new"; email = "foo@example.org"; }
        { github = "bar"; email = "bar@example.org"; }
      ];
      meta.outPath = "${placeholder "out"}";
    };
}

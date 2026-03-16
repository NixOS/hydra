with import ./config.nix;
{
  full-of-meta =
    mkDerivation {
      name = "full-of-meta";
      builder = ./empty-dir-builder.sh;

      meta = {
        description = "This is the description of the job.";
        license = [ { shortName = "MIT"; } "BSD" ];
        homepage = "https://example.com/";
        maintainers = [ "alice@example.com" { email = "bob@not.found"; } ];

        outPath = "${placeholder "out"}";
      };
    };
}

{ hydraSrc ? { outPath = ./.; revCount = 1234; gitTag = "abcdef"; }
, officialRelease ? false
}:


rec {
  tarball =
    with import <nixpkgs> { };

    let nix = nixUnstable; in

    releaseTools.makeSourceTarball {
      name = "hydra-tarball";
      src = hydraSrc;
      inherit officialRelease;
      version = builtins.readFile ./version;

      buildInputs =
        [ perl libxslt dblatex tetex nukeReferences pkgconfig boehmgc git openssl];

      versionSuffix = if officialRelease then "" else "pre${toString hydraSrc.revCount}-${hydraSrc.gitTag}";

      preConfigure = ''
        # TeX needs a writable font cache.
        export VARTEXFONTS=$TMPDIR/texfonts
      '';

      configureFlags =
        [ "--with-nix=${nix}"
          "--with-docbook-xsl=${docbook_xsl}/xml/xsl/docbook"
        ];

      postDist = ''
        make -C doc/manual install prefix="$out"
        nuke-refs "$out/share/doc/hydra/manual.pdf"

        echo "doc manual $out/share/doc/hydra manual.html" >> \
          "$out/nix-support/hydra-build-products"
        echo "doc-pdf manual $out/share/doc/hydra/manual.pdf" >> \
          "$out/nix-support/hydra-build-products"
      '';
    };

  build =
    { system ? "x86_64-linux" }:

    let pkgs = import <nixpkgs> {inherit system;}; in

    with pkgs;

    let nix = nixUnstable; in

    releaseTools.nixBuild {
      name = "hydra";
      src = tarball;
      configureFlags = "--with-nix=${nix}";

      buildInputs =
        [ perl makeWrapper libtool nix unzip nukeReferences pkgconfig boehmgc sqlite git gitAndTools.topGit mercurial subversion bazaar openssl bzip2 ]
        ++ (import ./deps.nix) { inherit pkgs; };

      hydraPath = stdenv.lib.concatStringsSep ":" (map (p: "${p}/bin") ( [
        libxslt sqlite subversion openssh nix coreutils findutils
        gzip bzip2 lzma gnutar unzip git gitAndTools.topGit mercurial gnused graphviz bazaar
      ] ++ ( if stdenv.isLinux then [rpm dpkg cdrkit] else [] )));

      preConfigure = "patchShebangs .";

      postInstall = ''
        ensureDir $out/nix-support
        nuke-refs $out/share/doc/hydra/manual/manual.pdf

        for i in $out/bin/*; do
            wrapProgram $i \
                --prefix PERL5LIB ':' $out/libexec/hydra/lib:$PERL5LIB \
                --prefix PATH ':' $out/bin:$hydraPath \
                --set HYDRA_RELEASE ${tarball.version} \
                --set HYDRA_HOME $out/libexec/hydra \
                --set NIX_RELEASE ${nix.name}
        done
      ''; # */

      LOGNAME = "foo";

      meta = {
        description = "Build of Hydra on ${system}";
      };

      succeedOnFailure = true;
      keepBuildDirectory = true;
    };


  tests =
    { nixos ? ../nixos, system ? "x86_64-linux" }:

    let hydra = build { inherit system; }; in

    with import <nixos/lib/testing.nix> { inherit system; };

    {

      install = simpleTest {

        machine =
          { config, pkgs, ... }:
          { services.postgresql.enable = true;
            environment.systemPackages = [ hydra ];
          };

        testScript =
          ''
            $machine->waitForJob("postgresql");

            # Initialise the database and the state.
            $machine->mustSucceed
                ( "createdb -O root hydra",
                , "psql hydra -f ${hydra}/share/hydra/sql/hydra-postgresql.sql"
                , "mkdir /var/lib/hydra"
                );

            # Start the web interface.
            #$machine->mustSucceed("HYDRA_DATA=/var/lib/hydra HYDRA_DBI='dbi:Pg:dbname=hydra;user=hydra;' hydra-server >&2 &");
            #$machine->waitForOpenPort("3000");
          '';

      };

    };


}

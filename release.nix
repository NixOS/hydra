{ nixpkgs ? /etc/nixos/nixpkgs
, hydraSrc ? {outPath = ./.; rev = 1234;}
, officialRelease ? false
}:


rec {
  tarball = 
    let pkgs = import nixpkgs {};
    in with pkgs;

    releaseTools.makeSourceTarball {
      name = "hydra-tarball";
      src = hydraSrc;
      inherit officialRelease;

      buildInputs = [ perl libxslt dblatex tetex ] ;

      preConfigure = ''
        # TeX needs a writable font cache.
        export VARTEXFONTS=$TMPDIR/texfonts
      '';
    };

  build = 
    { system ? "x86_64-linux" }:

    let pkgs = import nixpkgs {inherit system;}; in

    with pkgs;

    let nix = nixSqlite; in

    releaseTools.nixBuild {
      name = "hydra";
      src = tarball; 
      configureFlags = "--with-nix=${nix}";

      buildInputs =
        [ perl makeWrapper libtool nix unzip nukeReferences ]
        ++ (import ./deps.nix) { inherit pkgs; };

      hydraPath = stdenv.lib.concatStringsSep ":" (map (p: "${p}/bin") ( [
        libxslt sqlite subversion openssh nix coreutils findutils
        gzip bzip2 lzma gnutar unzip git mercurial
        gnused graphviz
      ] ++ ( if stdenv.isLinux then [rpm dpkg cdrkit] else [] )));

      postInstall = ''
        ensureDir $out/nix-support
        nuke-refs $out/share/doc/hydra/manual/manual.pdf

        cp ${"${nixpkgs}/pkgs/build-support/fetchsvn/nix-prefetch-svn"} $out/bin/nix-prefetch-svn
        cp ${"${nixpkgs}/pkgs/build-support/fetchgit/nix-prefetch-git"} $out/bin/nix-prefetch-git
        cp ${"${nixpkgs}/pkgs/build-support/fetchhg/nix-prefetch-hg"} $out/bin/nix-prefetch-hg

        for i in $out/bin/*; do
            wrapProgram $i \
                --prefix PERL5LIB ':' $out/libexec/hydra/lib:$PERL5LIB \
                --prefix PATH ':' $out/bin:$hydraPath \
                --set HYDRA_HOME $out/libexec/hydra \
                --set HYDRA_RELEASE ${tarball.version} \
                --set NIX_RELEASE ${nix.name}
        done

        echo "doc-pdf manual $out/share/doc/hydra/manual/manual.pdf" >> $out/nix-support/hydra-build-products
      ''; # */

      meta = {
        description = "Build of Hydra on ${system}";
      };
    };


  tests =
    { nixos ? ../nixos, system ? "x86_64-linux" }:

    let hydra = build { inherit system; }; in

    with import "${nixos}/lib/testing.nix" { inherit nixpkgs system; services = null; };

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
            #$machine->mustSucceed("HYDRA_DATA=/var/lib/hydra HYDRA_DBI='dbi:Pg:dbname=hydra;user=hydra;' hydra_server.pl >&2 &");
            #$machine->waitForOpenPort("3000");
          '';
          
      };
      
    };


}

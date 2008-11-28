let


  jobs = rec {


    tarball =
      { hydraSrc ? {path = ./.; rev = 1234;}
      , nixpkgs ? {path = ../nixpkgs;}
      , officialRelease ? false
      }:

      with import nixpkgs.path {};

      releaseTools.makeSourceTarball {
        name = "hydra-tarball";
        src = hydraSrc;
        inherit officialRelease;

        # Since we don't have a `make dist', just tar everything.
        distPhase = ''
          releaseName=hydra-0.1$VERSION_SUFFIX;
          ensureDir $out/tarballs
          mkdir ../$releaseName
          cp -prd . ../$releaseName
          cd ..
          tar cfj $out/tarballs/$releaseName.tar.bz2 $releaseName
          tar cfz $out/tarballs/$releaseName.tar.gz $releaseName
        '';
      };


    build = 
      { tarball ? {path = jobs.tarball {};}
      , nixpkgs ? {path = ../nixpkgs;}
      , system ? "i686-linux"
      }:

      with import nixpkgs.path {inherit system;};

      stdenvNew.mkDerivation {
        name = "hydra-build";

        buildInputs = [
          perl makeWrapper unzip
          perlCatalystDevel
          perlCatalystPluginAuthenticationStoreDBIC
          perlCatalystPluginSessionStoreFastMmap
          perlCatalystPluginStackTrace
          perlCatalystPluginAuthenticationStoreDBIxClass
          perlCatalystViewTT
        ];

        preUnpack = ''
          src=$(ls ${tarball.path}/tarballs/*.tar.bz2)
        ''; # */

        jquery = fetchurl {
          url = http://jqueryjs.googlecode.com/files/jquery-1.2.6.pack.js;
          sha1 = "c10dbe0c2b23444d0794f3376398702d84f41583";
        };

        tablesorter = fetchurl {
          url = http://tablesorter.com/jquery.tablesorter.zip;
          sha256 = "013zgglvifvy0yg0ybjrl823sswy9v1ihf5nmighmcyigfd6nrhb";
        };

        installPhase = ''
          ensureDir $out/libexec
          cp -prd src/Hydra $out/libexec/hydra

          cp $jquery $out/libexec/hydra/root/static/js/jquery-pack.js
          unzip -d $out/libexec/hydra/root/static/js $tablesorter

          mv $out/libexec/hydra/script $out/bin

          for i in $out/bin/*; do
              wrapProgram $i \
                  --prefix PERL5LIB ':' $out/libexec/hydra/lib:$PERL5LIB \
                  --prefix PATH ':' $out/bin \
                  --set HYDRA_HOME $out/libexec/hydra
          done
        ''; # */
      };

  };


in jobs

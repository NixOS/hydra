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

        buildInputs = [zip unzip];

        jquery = fetchurl {
          url = http://jqueryjs.googlecode.com/files/jquery-1.2.6.pack.js;
          sha1 = "c10dbe0c2b23444d0794f3376398702d84f41583";
        };

        tablesorter = fetchurl {
          url = http://tablesorter.com/jquery.tablesorter.zip;
          sha256 = "013zgglvifvy0yg0ybjrl823sswy9v1ihf5nmighmcyigfd6nrhb";
        };

        # Since we don't have a `make dist', just tar everything.
        distPhase = ''
          cp $jquery src/Hydra/root/static/js/jquery-pack.js
          unzip -d src/Hydra/root/static/js $tablesorter
        
          releaseName=hydra-0.1$VERSION_SUFFIX;
          ensureDir $out/tarballs
          mkdir ../$releaseName
          cp -prd . ../$releaseName
          cd ..
          tar cfj $out/tarballs/$releaseName.tar.bz2 $releaseName
          tar cfz $out/tarballs/$releaseName.tar.gz $releaseName
          zip -9r $out/tarballs/$releaseName.zip $releaseName
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
          perl makeWrapper
          perlCatalystDevel
          perlCatalystPluginAuthenticationStoreDBIC
          perlCatalystPluginSessionStoreFastMmap
          perlCatalystPluginStackTrace
          perlCatalystPluginAuthenticationStoreDBIxClass
          perlCatalystViewTT
          perlXMLSimple
          perlIPCRun
        ];

        preUnpack = ''
          src=$(ls ${tarball.path}/tarballs/*.tar.bz2)
        ''; # */

        hydraPath = stdenv.lib.concatStringsSep ":" (map (p: "${p}/bin") [
          libxslt sqlite subversion nixUnstable coreutils
          gzip bzip2 gnused
        ]);

        installPhase = ''
          ensureDir $out/libexec
          cp -prd src/Hydra $out/libexec/hydra

          mv $out/libexec/hydra/script $out/bin

          cp ${nixpkgs.path + "/pkgs/build-support/fetchsvn/nix-prefetch-svn"} $out/bin/nix-prefetch-svn

          for i in $out/bin/*; do
              wrapProgram $i \
                  --prefix PERL5LIB ':' $out/libexec/hydra/lib:$PERL5LIB \
                  --set PATH $out/bin:$hydraPath \
                  --set HYDRA_HOME $out/libexec/hydra
          done
        ''; # */

        meta = {
          description = "Build of Hydra on ${system}";
        };
      };

  };


in jobs

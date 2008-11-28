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
          perl makeWrapper
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

        installPhase = ''
          ensureDir $out/libexec
          cp -prd src/Hydra $out/libexec/hydra

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

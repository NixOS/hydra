{ nixpkgs ? ../nixpkgs
, hydraSrc ? {outPath = ./.; rev = 1234;}
, officialRelease ? false
}:


rec {

  tarball =
    with import nixpkgs {};

    releaseTools.makeSourceTarball {
      name = "hydra-tarball";
      version = "0.1";
      src = hydraSrc;
      inherit officialRelease;

      buildInputs = [zip unzip];

      jquery = fetchurl {
        url = http://jqueryui.com/download/jquery-ui-1.7.2.custom.zip;
        sha256 = "1l9dwaaqvdysmzlkg1vb8j0s0xn63d475gh53pjjwxw85668krdh";
      };

      tablesorter = fetchurl {
        url = http://tablesorter.com/jquery.tablesorter.zip;
        sha256 = "013zgglvifvy0yg0ybjrl823sswy9v1ihf5nmighmcyigfd6nrhb";
      };

      flot = fetchurl {
        url = http://flot.googlecode.com/files/flot-0.6.zip;
        sha256 = "1k2mfijvr1jwga65wcd78lp9ia17v99f1cfm5nlmc0k8glllbj5a";
      };

      # Since we don't have a `make dist', just tar everything.
      distPhase = ''
        ensureDir src/root/static/js/jquery
        unzip -d src/root/static/js/jquery $jquery
        rm -rf src/root/static/js/tablesorter
        unzip -d src/root/static/js $tablesorter
        unzip -d src/root/static/js $flot

        make -C src/sql

        releaseName=hydra-0.1$VERSION_SUFFIX
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
    { system ? "x86_64-linux" }:

    let pkgs = import nixpkgs {inherit system;}; in

    with pkgs;

    let nix = nixSqlite; in

    stdenv.mkDerivation {
      name = "hydra-${tarball.version}";

      buildInputs =
        [ perl makeWrapper libtool ]
        ++ (import ./deps.nix) { inherit pkgs; };

      preUnpack = ''
        src=$(ls ${tarball}/tarballs/*.tar.bz2)
      ''; # */

      hydraPath = stdenv.lib.concatStringsSep ":" (map (p: "${p}/bin") ( [
        libxslt sqlite subversion openssh nix coreutils findutils
        gzip bzip2 lzma gnutar unzip git
        gnused graphviz
      ] ++ ( if stdenv.isLinux then [rpm dpkg cdrkit] else [] )));

      installPhase = ''
        ensureDir $out/nix-support

        ensureDir $out/libexec
        cp -prd src $out/libexec/hydra

        mv $out/libexec/hydra/script $out/bin

        cp ${"${nixpkgs}/pkgs/build-support/fetchsvn/nix-prefetch-svn"} $out/bin/nix-prefetch-svn
        cp ${"${nixpkgs}/pkgs/build-support/fetchgit/nix-prefetch-git"} $out/bin/nix-prefetch-git

        make -C src/c NIX=${nix} ATERM=${aterm}
        cp src/c/hydra_eval_jobs $out/bin

        for i in $out/bin/*; do
            wrapProgram $i \
                --prefix PERL5LIB ':' $out/libexec/hydra/lib:$PERL5LIB \
                --prefix PATH ':' $out/bin:$hydraPath \
                --set HYDRA_HOME $out/libexec/hydra \
                --set HYDRA_RELEASE ${tarball.version} \
                --set NIX_RELEASE ${nix.name}
        done

        ensureDir $out/share/doc/hydra/manual
        cp doc/manual/* $out/share/doc/hydra/manual/
        ln -s manual.html $out/share/doc/hydra/manual/index.html
        echo "doc manual $out/share/doc/hydra/manual" >> $out/nix-support/hydra-build-products
        echo "nix-build none $out" >> $out/nix-support/hydra-build-products

        ensureDir $out/share/hydra/sql
        cp src/sql/*.sql $out/share/hydra/sql/
      ''; # */

      meta = {
        description = "Build of Hydra on ${system}";
      };
    };
    
}

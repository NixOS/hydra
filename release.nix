{ hydraSrc ? { outPath = ./.; revCount = 1234; gitTag = "abcdef"; }
, officialRelease ? false
}:

let

  pkgs = import <nixpkgs> {};

  genAttrs' = pkgs.lib.genAttrs [ "x86_64-linux" "i686-linux" ];

in rec {

  tarball =
    with import <nixpkgs> { };

    releaseTools.makeSourceTarball {
      name = "hydra-tarball";
      src = hydraSrc;
      inherit officialRelease;
      version = builtins.readFile ./version;

      buildInputs =
        [ perl libxslt dblatex tetex nukeReferences pkgconfig boehmgc git openssl ];

      versionSuffix = if officialRelease then "" else "pre${toString hydraSrc.revCount}-${hydraSrc.gitTag}";

      preHook = ''
        # TeX needs a writable font cache.
        export VARTEXFONTS=$TMPDIR/texfonts

        addToSearchPath PATH $(pwd)/src/script
        addToSearchPath PATH $(pwd)/src/c
        addToSearchPath PERL5LIB $(pwd)/src/lib
      '';

      configureFlags =
        [ "--with-nix=${nixUnstable}"
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


  build = genAttrs' (system:

    with import <nixpkgs> { inherit system; };

    let

      nix = nixUnstable;

      perlDeps = buildEnv {
        name = "hydra-perl-deps";
        paths = with perlPackages;
          [ ModulePluggable
            CatalystAuthenticationStoreDBIxClass
            CatalystDispatchTypeRegex
            CatalystPluginAccessLog
            CatalystPluginAuthorizationRoles
            CatalystPluginCaptcha
            CatalystPluginSessionStateCookie
            CatalystPluginSessionStoreFastMmap
            CatalystPluginStackTrace
            CatalystTraitForRequestProxyBase
            CatalystViewDownload
            CatalystViewJSON
            CatalystViewTT
            CatalystXScriptServerStarman
            CatalystActionREST
            CryptRandPasswd
            DBDPg
            DBDSQLite
            DataDump
            DateTime
            DigestSHA1
            EmailSender
            FileSlurp
            LWP
            LWPProtocolHttps
            IOCompress
            IPCRun
            JSONXS
            PadWalker
            CatalystDevel
            Readonly
            SetScalar
            SQLSplitStatement
            Starman
            SysHostnameLong
            TestMore
            TextDiff
            TextTable
            XMLSimple
            nix git
          ];
      };

    in

    releaseTools.nixBuild {
      name = "hydra";
      src = tarball;
      configureFlags = "--with-nix=${nix}";

      buildInputs =
        [ makeWrapper libtool unzip nukeReferences pkgconfig boehmgc sqlite
          gitAndTools.topGit mercurial subversion bazaar openssl bzip2
          guile # optional, for Guile + Guix support
          perlDeps perl
        ];

      hydraPath = lib.makeSearchPath "bin" (
        [ libxslt sqlite subversion openssh nix coreutils findutils
          gzip bzip2 lzma gnutar unzip git gitAndTools.topGit mercurial gnused graphviz bazaar
        ] ++ lib.optionals stdenv.isLinux [ rpm dpkg cdrkit ] );

      preCheck = ''
        patchShebangs .
        export LOGNAME=${LOGNAME:-foo}
      '';

      postInstall = ''
        mkdir -p $out/nix-support
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

      meta.description = "Build of Hydra on ${system}";
    });


  tests.install = genAttrs' (system:
    with import <nixos/lib/testing.nix> { inherit system; };
    let hydra = builtins.getAttr system build; in # build.${system}
    simpleTest {
      machine =
        { config, pkgs, ... }:
        { services.postgresql.enable = true;
          services.postgresql.package = pkgs.postgresql92;
          environment.systemPackages = [ hydra ];
        };

      testScript =
        ''
          $machine->waitForJob("postgresql");

          # Initialise the database and the state.
          $machine->mustSucceed
              ( "createdb -O root hydra",
              , "psql hydra -f ${hydra}/libexec/hydra/sql/hydra-postgresql.sql"
              , "mkdir /var/lib/hydra"
              );

          # Start the web interface.
          $machine->mustSucceed("HYDRA_DATA=/var/lib/hydra HYDRA_DBI='dbi:Pg:dbname=hydra;user=hydra;' hydra-server >&2 &");
          $machine->waitForOpenPort("3000");
        '';
    });

  tests.api = genAttrs' (system:
    with import <nixos/lib/testing.nix> { inherit system; };
    let hydra = builtins.getAttr system build; in # build."${system}"
    simpleTest {
      machine =
        { config, pkgs, ... }:
        { services.postgresql.enable = true;
          services.postgresql.package = pkgs.postgresql92;
          environment.systemPackages = [ hydra pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];
          virtualisation.memorySize = 2047;
          boot.kernelPackages = pkgs.linuxPackages_3_10;
        };

      testScript =
        ''
          $machine->waitForJob("postgresql");

          # Initialise the database and the state.
          $machine->mustSucceed
              ( "createdb -O root hydra"
              , "psql hydra -f ${hydra}/libexec/hydra/sql/hydra-postgresql.sql"
              , "mkdir /var/lib/hydra"
              , "echo \"insert into Users(userName, emailAddress, password) values('root', 'e.dolstra\@tudelft.nl', '\$(echo -n foobar | sha1sum | cut -c1-40)');\" | psql hydra"
              , "echo \"insert into UserRoles(userName, role) values('root', 'admin');\" | psql hydra"
              , "mkdir /run/jobset"
              , "chmod 755 /run/jobset"
              , "cp ${./tests/api-test.nix} /run/jobset/default.nix"
              , "chmod 644 /run/jobset/default.nix"
              );

          # Start the web interface.
          $machine->mustSucceed("NIX_STORE_DIR=/run/nix NIX_LOG_DIR=/run/nix/var/log/nix NIX_STATE_DIR=/run/nix/var/nix HYDRA_DATA=/var/lib/hydra HYDRA_DBI='dbi:Pg:dbname=hydra;user=root;' LOGNAME=root DBIC_TRACE=1 hydra-server -d >&2 &");
          $machine->waitForOpenPort("3000");

          $machine->mustSucceed("perl ${./tests/api-test.pl} >&2");
        '';
  });
}

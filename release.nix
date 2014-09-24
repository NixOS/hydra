{ hydraSrc ? { outPath = ./.; revCount = 1234; gitTag = "abcdef"; }
, officialRelease ? false
}:

let

  pkgs = import <nixpkgs> {};

  genAttrs' = pkgs.lib.genAttrs [ "x86_64-linux" ];

  hydraServer = hydraPkg:
    { config, pkgs, ... }:
    { imports = [ ./hydra-module.nix ];

      virtualisation.memorySize = 1024;

      services.hydra.enable = true;
      services.hydra.package = hydraPkg;
      services.hydra.hydraURL = "http://hydra.example.org";
      services.hydra.notificationSender = "admin@hydra.example.org";

      services.postgresql.enable = true;
      services.postgresql.package = pkgs.postgresql92;

      environment.systemPackages = [ pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];
    };

in rec {

  tarball =
    with import <nixpkgs> { };

    releaseTools.makeSourceTarball {
      name = "hydra-tarball";
      src = hydraSrc;
      inherit officialRelease;
      version = builtins.readFile ./version;

      buildInputs =
        [ perl libxslt dblatex tetex nukeReferences pkgconfig nixUnstable git openssl ];

      versionSuffix = if officialRelease then "" else "pre${toString hydraSrc.revCount}-${hydraSrc.gitTag}";

      preHook = ''
        # TeX needs a writable font cache.
        export VARTEXFONTS=$TMPDIR/texfonts

        addToSearchPath PATH $(pwd)/src/script
        addToSearchPath PATH $(pwd)/src/c
        addToSearchPath PERL5LIB $(pwd)/src/lib
      '';

      configureFlags =
        [ "--with-docbook-xsl=${docbook_xsl}/xml/xsl/docbook" ];

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
            CatalystPluginUnicodeEncoding
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
            NetAmazonS3
            nix git
          ];
      };

    in

    releaseTools.nixBuild {
      name = "hydra";
      src = tarball;

      buildInputs =
        [ makeWrapper libtool unzip nukeReferences pkgconfig sqlite
          gitAndTools.topGit mercurial darcs subversion bazaar openssl bzip2
          guile # optional, for Guile + Guix support
          perlDeps perl
        ];

      hydraPath = lib.makeSearchPath "bin" (
        [ libxslt sqlite subversion openssh nix coreutils findutils
          gzip bzip2 lzma gnutar unzip git gitAndTools.topGit mercurial darcs gnused graphviz bazaar
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
                --set NIX_RELEASE ${nix.name or "unknown"}
        done
      ''; # */

      meta.description = "Build of Hydra on ${system}";
      passthru.perlDeps = perlDeps;
    });


  tests.install = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    simpleTest {
      machine = hydraServer (builtins.getAttr system build); # build.${system}
      testScript =
        ''
          $machine->waitForJob("hydra-init");
          $machine->waitForJob("hydra-server");
          $machine->waitForJob("hydra-evaluator");
          $machine->waitForJob("hydra-queue-runner");
          $machine->waitForOpenPort("3000");
          $machine->succeed("curl --fail http://localhost:3000/");
        '';
    });

  tests.api = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    simpleTest {
      machine = hydraServer (builtins.getAttr system build); # build.${system}
      testScript =
        let dbi = "dbi:Pg:dbname=hydra;user=root;"; in
        ''
          $machine->waitForJob("hydra-init");

          # Create an admin account and some other state.
          $machine->succeed
              ( "su hydra -c \"hydra-create-user root --email-address 'e.dolstra\@tudelft.nl' --password foobar --role admin\""
              , "mkdir /run/jobset /tmp/nix"
              , "chmod 755 /run/jobset /tmp/nix"
              , "cp ${./tests/api-test.nix} /run/jobset/default.nix"
              , "chmod 644 /run/jobset/default.nix"
              , "chown -R hydra /run/jobset /tmp/nix"
              );

          # Start the web interface with some weird settings.
          $machine->succeed("systemctl stop hydra-server hydra-evaluator hydra-queue-runner");
          $machine->mustSucceed("su hydra -c 'NIX_STORE_DIR=/tmp/nix/store NIX_LOG_DIR=/tmp/nix/var/log/nix NIX_STATE_DIR=/tmp/nix/var/nix DBIC_TRACE=1 hydra-server -d' >&2 &");
          $machine->waitForOpenPort("3000");

          # Run the API tests.
          $machine->mustSucceed("su hydra -c 'perl ${./tests/api-test.pl}' >&2");
        '';
  });

  /*
  tests.s3backup = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    let hydra = builtins.getAttr system build; in # build."${system}"
    simpleTest {
      machine =
        { config, pkgs, ... }:
        { services.postgresql.enable = true;
          services.postgresql.package = pkgs.postgresql92;
          environment.systemPackages = [ hydra pkgs.rubyLibs.fakes3 ];
          virtualisation.memorySize = 2047;
          boot.kernelPackages = pkgs.linuxPackages_3_10;
          virtualisation.writableStore = true;
          networking.extraHosts = ''
            127.0.0.1 hydra.s3.amazonaws.com
          '';
        };

      testScript =
        ''
          $machine->waitForJob("postgresql");

          # Initialise the database and the state.
          $machine->succeed
              ( "createdb -O root hydra"
              , "psql hydra -f ${hydra}/libexec/hydra/sql/hydra-postgresql.sql"
              , "mkdir /var/lib/hydra"
              , "mkdir /tmp/jobs"
              , "cp ${./tests/s3-backup-test.pl} /tmp/s3-backup-test.pl"
              , "cp ${./tests/api-test.nix} /tmp/jobs/default.nix"
              );

          # start fakes3
          $machine->succeed("fakes3 --root /tmp/s3 --port 80 &>/dev/null &");
          $machine->waitForOpenPort("80");

          $machine->succeed("cd /tmp && LOGNAME=root AWS_ACCESS_KEY_ID=foo AWS_SECRET_ACCESS_KEY=bar HYDRA_DBI='dbi:Pg:dbname=hydra;user=root;' HYDRA_CONFIG=${./tests/s3-backup-test.config} perl -I ${hydra}/libexec/hydra/lib -I ${hydra.perlDeps}/lib/perl5/site_perl ./s3-backup-test.pl >&2");
        '';
  });
  */
}

{ hydraSrc ? { outPath = ./.; revCount = 1234; rev = "abcdef"; }
, officialRelease ? false
, shell ? false
}:

with import <nixpkgs/lib>;

let

  pkgs = import <nixpkgs> {};

  genAttrs' = genAttrs [ "x86_64-linux" /* "i686-linux" */ ];

  hydraServer = hydraPkg:
    { config, pkgs, ... }:
    { imports = [ ./hydra-module.nix ];

      virtualisation.memorySize = 1024;
      virtualisation.writableStore = true;

      services.hydra-dev.enable = true;
      services.hydra-dev.package = hydraPkg;
      services.hydra-dev.hydraURL = "http://hydra.example.org";
      services.hydra-dev.notificationSender = "admin@hydra.example.org";

      services.postgresql.enable = true;
      services.postgresql.package = pkgs.postgresql92;

      environment.systemPackages = [ pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];
    };

  version = builtins.readFile ./version + "." + toString hydraSrc.revCount + "." + hydraSrc.rev;

in

rec {

  build = genAttrs' (system:

    with import <nixpkgs> { inherit system; };

    let

      aws-sdk-cpp' =
        aws-sdk-cpp.override {
          apis = ["s3"];
          customMemoryManagement = false;
        };

        /*
      nix = overrideDerivation nixUnstable (attrs: {
        src = fetchFromGitHub {
          owner = "NixOS";
          repo = "nix";
          rev = "4be4f6de56f4de77f6a376f1a40ed75eb641bb89";
          sha256 = "0icvbwpca1jh8qkdlayxspdxl5fb0qjjd1kn74x6gs6iy66kndq6";
        };
        buildInputs = attrs.buildInputs ++ [ autoreconfHook bison flex ];
        nativeBuildInputs = attrs.nativeBuildInputs ++ [ aws-sdk-cpp' autoconf-archive ];
        configureFlags = attrs.configureFlags + " --disable-doc-gen";
        preConfigure = "./bootstrap.sh; mkdir -p $doc $man";
      });
      */
      nix = nixUnstable;

      perlDeps = buildEnv {
        name = "hydra-perl-deps";
        paths = with perlPackages;
          [ ModulePluggable
            CatalystActionREST
            CatalystAuthenticationStoreDBIxClass
            CatalystDevel
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
            CryptRandPasswd
            DBDPg
            DBDSQLite
            DataDump
            DateTime
            DigestSHA1
            EmailMIME
            EmailSender
            FileSlurp
            IOCompress
            IPCRun
            JSONXS
            LWP
            LWPProtocolHttps
            NetAmazonS3
            NetStatsd
            PadWalker
            Readonly
            SQLSplitStatement
            SetScalar
            Starman
            SysHostnameLong
            TestMore
            TextDiff
            TextTable
            XMLSimple
            nix
            nix.perl-bindings
            git
            boehmgc
            aws-sdk-cpp'
          ];
      };

    in

    releaseTools.nixBuild {
      name = "hydra-${version}";

      src = if shell then null else hydraSrc;

      stdenv = overrideCC stdenv gcc6;

      buildInputs =
        [ makeWrapper autoconf automake libtool unzip nukeReferences pkgconfig sqlite libpqxx
          gitAndTools.topGit mercurial darcs subversion bazaar openssl bzip2 libxslt
          guile # optional, for Guile + Guix support
          perlDeps perl nix
          postgresql92 # for running the tests
        ];

      hydraPath = lib.makeBinPath (
        [ sqlite subversion openssh nix coreutils findutils pixz
          gzip bzip2 lzma gnutar unzip git gitAndTools.topGit mercurial darcs gnused bazaar
        ] ++ lib.optionals stdenv.isLinux [ rpm dpkg cdrkit ] );

      postUnpack = optionalString (!shell) ''
        # Clean up when building from a working tree.
        (cd $sourceRoot && (git ls-files -o --directory | xargs -r rm -rfv)) || true
      '';

      configureFlags = [ "--with-docbook-xsl=${docbook_xsl}/xml/xsl/docbook" ];

      preHook = ''
        PATH=$(pwd)/src/hydra-evaluator:$(pwd)/src/script:$(pwd)/src/hydra-eval-jobs:$(pwd)/src/hydra-queue-runner:$PATH
        ${lib.optionalString shell "PERL5LIB=$(pwd)/src/lib:$PERL5LIB"}
      '';

      preConfigure = "autoreconf -vfi";

      enableParallelBuilding = true;

      preCheck = ''
        patchShebangs .
        export LOGNAME=${LOGNAME:-foo}
      '';

      postInstall = ''
        mkdir -p $out/nix-support

        for i in $out/bin/*; do
            read -n 4 chars < $i
            if [[ $chars =~ ELF ]]; then continue; fi
            wrapProgram $i \
                --prefix PERL5LIB ':' $out/libexec/hydra/lib:$PERL5LIB \
                --prefix PATH ':' $out/bin:$hydraPath \
                --set HYDRA_RELEASE ${version} \
                --set HYDRA_HOME $out/libexec/hydra \
                --set NIX_RELEASE ${nix.name or "unknown"}
        done
      ''; # */

      dontStrip = true;

      meta.description = "Build of Hydra on ${system}";
      passthru.perlDeps = perlDeps;
    });

  manual = pkgs.runCommand "hydra-manual-${version}"
    { build = build.x86_64-linux;
    }
    ''
      mkdir -p $out/share
      cp -prvd $build/share/doc $out/share/

      mkdir $out/nix-support
      echo "doc manual $out/share/doc/hydra" >> $out/nix-support/hydra-build-products
    '';

  tests.install = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    simpleTest {
      machine = hydraServer build.${system};
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
      machine = hydraServer build.${system};
      testScript =
        let dbi = "dbi:Pg:dbname=hydra;user=root;"; in
        ''
          $machine->waitForJob("hydra-init");

          # Create an admin account and some other state.
          $machine->succeed
              ( "su - hydra -c \"hydra-create-user root --email-address 'alice\@example.org' --password foobar --role admin\""
              , "mkdir /run/jobset /tmp/nix"
              , "chmod 755 /run/jobset /tmp/nix"
              , "cp ${./tests/api-test.nix} /run/jobset/default.nix"
              , "chmod 644 /run/jobset/default.nix"
              , "chown -R hydra /run/jobset /tmp/nix"
              );

          $machine->succeed("systemctl stop hydra-evaluator hydra-queue-runner");
          $machine->waitForJob("hydra-server");
          $machine->waitForOpenPort("3000");

          # Run the API tests.
          $machine->mustSucceed("su - hydra -c 'perl ${./tests/api-test.pl}' >&2");
        '';
  });

  /*
  tests.s3backup = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    let hydra = build.${system}
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

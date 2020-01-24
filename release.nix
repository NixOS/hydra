{ hydraSrc ? builtins.fetchGit ./.
, nixpkgs ? builtins.fetchGit { url = https://github.com/NixOS/nixpkgs-channels.git; ref = "nixos-19.09-small"; }
, officialRelease ? false
, shell ? false
}:

with import (nixpkgs + "/lib");

let

  pkgs = import nixpkgs {};

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
      services.postgresql.package = pkgs.postgresql95;

      environment.systemPackages = [ pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];

      # The following is to work around the following error from hydra-server:
      #   [error] Caught exception in engine "Cannot determine local time zone"
      time.timeZone = "UTC";

      nix = {
        # The following is to work around: https://github.com/NixOS/hydra/pull/432
        buildMachines = [
          { hostName = "localhost";
            system = "x86_64-linux";
          }
        ];
        # Without this nix tries to fetch packages from the default
        # cache.nixos.org which is not reachable from this sandboxed NixOS test.
        binaryCaches = [];
      };
    };

  version = builtins.readFile ./version + "." + toString hydraSrc.revCount + "." + hydraSrc.rev;

in

rec {

  build = genAttrs' (system:
    let pkgs = import nixpkgs { inherit system; }; in

    with pkgs;

    let

      nix = pkgs.nixUnstable or pkgs.nix;

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
            CatalystXRoleApplicator
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
            JSON
            JSONAny
            JSONXS
            LWP
            LWPProtocolHttps
            NetAmazonS3
            NetPrometheus
            NetStatsd
            PadWalker
            Readonly
            SQLSplitStatement
            SetScalar
            Starman
            SysHostnameLong
            TermSizeAny
            TestMore
            TextDiff
            TextTable
            XMLSimple
            nix
            nix.perl-bindings
            git
            boehmgc
          ];
      };

    in

    releaseTools.nixBuild {
      name = "hydra-${version}";

      src = if shell then null else hydraSrc;

      buildInputs =
        [ makeWrapper autoconf automake libtool unzip nukeReferences pkgconfig sqlite libpqxx
          gitAndTools.topGit mercurial darcs subversion bazaar openssl bzip2 libxslt
          guile # optional, for Guile + Guix support
          perlDeps perl nix
          postgresql95 # for running the tests
          boost
          nlohmann_json
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

      shellHook = ''
        PATH=$(pwd)/src/hydra-evaluator:$(pwd)/src/script:$(pwd)/src/hydra-eval-jobs:$(pwd)/src/hydra-queue-runner:$PATH
        ${lib.optionalString shell "PERL5LIB=$(pwd)/src/lib:$PERL5LIB"}
      '';

      preConfigure = "autoreconf -vfi";

      NIX_LDFLAGS = [
          "-lpthread"
	];

      enableParallelBuilding = true;

      preCheck = ''
        patchShebangs .
        export LOGNAME=''${LOGNAME:-foo}
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
    with import (nixpkgs + "/nixos/lib/testing.nix") { inherit system; };
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
    with import (nixpkgs + "/nixos/lib/testing.nix") { inherit system; };
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
          $machine->mustSucceed("su - hydra -c 'perl -I ${build.${system}.perlDeps}/lib/perl5/site_perl ${./tests/api-test.pl}' >&2");
        '';
  });

  tests.notifications = genAttrs' (system:
    with import (nixpkgs + "/nixos/lib/testing.nix") { inherit system; };
    simpleTest {
      machine = { pkgs, ... }: {
        imports = [ (hydraServer build.${system}) ];
        services.hydra-dev.extraConfig = ''
          <influxdb>
            url = http://127.0.0.1:8086
            db = hydra
          </influxdb>
        '';
        services.influxdb.enable = true;
      };
      testScript = ''
        $machine->waitForJob("hydra-init");

        # Create an admin account and some other state.
        $machine->succeed
            ( "su - hydra -c \"hydra-create-user root --email-address 'alice\@example.org' --password foobar --role admin\""
            , "mkdir /run/jobset"
            , "chmod 755 /run/jobset"
            , "cp ${./tests/api-test.nix} /run/jobset/default.nix"
            , "chmod 644 /run/jobset/default.nix"
            , "chown -R hydra /run/jobset"
            );

        # Wait until InfluxDB can receive web requests
        $machine->waitForJob("influxdb");
        $machine->waitForOpenPort("8086");

        # Create an InfluxDB database where hydra will write to
        $machine->succeed(
          "curl -XPOST 'http://127.0.0.1:8086/query' \\
          --data-urlencode 'q=CREATE DATABASE hydra'");

        # Wait until hydra-server can receive HTTP requests
        $machine->waitForJob("hydra-server");
        $machine->waitForOpenPort("3000");

        # Setup the project and jobset
        $machine->mustSucceed(
          "su - hydra -c 'perl -I ${build.${system}.perlDeps}/lib/perl5/site_perl ${./tests/setup-notifications-jobset.pl}' >&2");

        # Wait until hydra has build the job and
        # the InfluxDBNotification plugin uploaded its notification to InfluxDB
        $machine->waitUntilSucceeds(
          "curl -s -H 'Accept: application/csv' \\
          -G 'http://127.0.0.1:8086/query?db=hydra' \\
          --data-urlencode 'q=SELECT * FROM hydra_build_status' | grep success");
      '';
  });

  /*
  tests.s3backup = genAttrs' (system:
    with import (nixpkgs + "/nixos/lib/testing.nix") { inherit system; };
    let hydra = build.${system}
    simpleTest {
      machine =
        { config, pkgs, ... }:
        { services.postgresql.enable = true;
          services.postgresql.package = pkgs.postgresql95;
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

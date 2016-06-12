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

      services.hydra.enable = true;
      services.hydra.package = hydraPkg;
      services.hydra.hydraURL = "http://hydra.example.org";
      services.hydra.notificationSender = "admin@hydra.example.org";

      services.postgresql.enable = true;
      services.postgresql.package = pkgs.postgresql92;

      environment.systemPackages = [ pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];
    };

  version = builtins.readFile ./version + "." + toString hydraSrc.revCount + "." + hydraSrc.rev;

in

assert versionAtLeast (getVersion pkgs.nixUnstable) "1.11pre4244_133a421";

rec {

  build = genAttrs' (system:

    with import <nixpkgs> { inherit system; };

    let

      nix = nixUnstable;

      NetStatsd = buildPerlPackage {
        name = "Net-Statsd-0.11";
        src = fetchurl {
          url = mirror://cpan/authors/id/C/CO/COSIMO/Net-Statsd-0.11.tar.gz;
          sha256 = "0f56c95846c7e65e6d32cec13ab9df65716429141f106d2dc587f1de1e09e163";
        };
        meta = {
          description = "Sends statistics to the stats daemon over UDP";
          license = "perl";
        };
      };

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
            URI
            XMLSimple
            nix git boehmgc
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
          postgresql92 # for running the tests
          (lib.overrideDerivation (aws-sdk-cpp.override {
            apis = ["s3"];
            customMemoryManagement = false;
          }) (attrs: {
            src = fetchFromGitHub {
              owner = "edolstra";
              repo = "aws-sdk-cpp";
              rev = "local";
              sha256 = "1vhgsxkhpai9a7dk38q4r239l6dsz2jvl8hii24c194lsga3g84h";
            };
          }))
        ];

      hydraPath = lib.makeBinPath (
        [ libxslt sqlite subversion openssh nix coreutils findutils
          gzip bzip2 lzma gnutar unzip git gitAndTools.topGit mercurial darcs gnused bazaar
        ] ++ lib.optionals stdenv.isLinux [ rpm dpkg cdrkit ] );

      postUnpack = optionalString (!shell) ''
        # Clean up when building from a working tree.
        (cd $sourceRoot && (git ls-files -o --directory | xargs -r rm -rfv)) || true
      '';

      configureFlags = [ "--with-docbook-xsl=${docbook_xsl}/xml/xsl/docbook" ];

      preHook = ''
        PATH=$(pwd)/src/script:$(pwd)/src/hydra-eval-jobs:$(pwd)/src/hydra-queue-runner:$PATH
        PERL5LIB=$(pwd)/src/lib:$PERL5LIB;
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

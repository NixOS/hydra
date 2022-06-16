{
  description = "A Nix-based continuous build system";

  # FIXME: All the pinned versions of nix/nixpkgs have a broken foreman (yes,
  # even 2.7.0's Nixpkgs pin).
  inputs.newNixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
  inputs.nixpkgs.follows = "nix/nixpkgs";
  inputs.nix.url = "github:NixOS/nix/2.9.1";

  outputs = { self, newNixpkgs, nixpkgs, nix }:
    let

      version = "${builtins.readFile ./version.txt}.${builtins.substring 0 8 (self.lastModifiedDate or "19700101")}.${self.shortRev or "DIRTY"}";

      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ self.overlay nix.overlay ];
      };

      # NixOS configuration used for VM tests.
      hydraServer =
        { config, pkgs, ... }:
        {
          imports = [ self.nixosModules.hydraTest ];

          virtualisation.memorySize = 1024;
          virtualisation.writableStore = true;

          environment.systemPackages = [ pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];

          nix = {
            # Without this nix tries to fetch packages from the default
            # cache.nixos.org which is not reachable from this sandboxed NixOS test.
            binaryCaches = [ ];
          };
        };

    in
    rec {

      # A Nixpkgs overlay that provides a 'hydra' package.
      overlay = final: prev: {

        # Overlay these packages to use dependencies from the Nixpkgs everything
        # else uses, to side-step the version difference: glibc is 2.32 in the
        # nix-pinned Nixpkgs, but 2.33 in the newNixpkgs commit.
        civetweb = (final.callPackage "${newNixpkgs}/pkgs/development/libraries/civetweb" { }).overrideAttrs
          # Can be dropped once newNixpkgs points to a revision containing
          # https://github.com/NixOS/nixpkgs/pull/167751
          ({ cmakeFlags ? [ ], ... }: {
            cmakeFlags = cmakeFlags ++ [
              "-DCIVETWEB_ENABLE_IPV6=1"
            ];
          });
        prometheus-cpp = final.callPackage "${newNixpkgs}/pkgs/development/libraries/prometheus-cpp" { };

        # Add LDAP dependencies that aren't currently found within nixpkgs.
        perlPackages = prev.perlPackages // {
          TestPostgreSQL = final.perlPackages.buildPerlModule {
            pname = "Test-PostgreSQL";
            version = "1.28-1";
            src = final.fetchFromGitHub {
              owner = "grahamc";
              repo = "Test-postgresql";
              rev = "release-1.28-1";
              hash = "sha256-SFC1C3q3dbcBos18CYd/s0TIcfJW4g04ld0+XQXVToQ=";
            };
            buildInputs = with final.perlPackages; [ ModuleBuildTiny TestSharedFork pkgs.postgresql ];
            propagatedBuildInputs = with final.perlPackages; [ DBDPg DBI FileWhich FunctionParameters Moo TieHashMethod TryTiny TypeTiny ];

            makeMakerFlags = "POSTGRES_HOME=${final.postgresql}";

            meta = {
              homepage = "https://github.com/grahamc/Test-postgresql/releases/tag/release-1.28-1";
              description = "PostgreSQL runner for tests";
              license = with final.lib.licenses; [ artistic2 ];
            };
          };

          FunctionParameters = final.perlPackages.buildPerlPackage {
            pname = "Function-Parameters";
            version = "2.001003";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/M/MA/MAUKE/Function-Parameters-2.001003.tar.gz";
              sha256 = "eaa22c6b43c02499ec7db0758c2dd218a3b2ab47a714b2bdf8010b5ee113c242";
            };
            buildInputs = with final.perlPackages; [ DirSelf TestFatal ];
            meta = {
              description = "Define functions and methods with parameter lists (\"subroutine signatures\")";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          CatalystPluginPrometheusTiny = final.perlPackages.buildPerlPackage {
            pname = "Catalyst-Plugin-PrometheusTiny";
            version = "0.005";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/S/SY/SYSPETE/Catalyst-Plugin-PrometheusTiny-0.005.tar.gz";
              sha256 = "a42ef09efdc3053899ae007c41220d3ed7207582cc86e491b4f534539c992c5a";
            };
            buildInputs = with final.perlPackages; [ HTTPMessage Plack SubOverride TestDeep ];
            propagatedBuildInputs = with final.perlPackages; [ CatalystRuntime Moose PrometheusTiny PrometheusTinyShared ];
            meta = {
              description = "Prometheus metrics for Catalyst";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          CryptArgon2 = final.perlPackages.buildPerlModule {
            pname = "Crypt-Argon2";
            version = "0.010";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/L/LE/LEONT/Crypt-Argon2-0.010.tar.gz";
              sha256 = "3ea1c006f10ef66fd417e502a569df15c4cc1c776b084e35639751c41ce6671a";
            };
            nativeBuildInputs = [ pkgs.ld-is-cc-hook ];
            meta = {
              description = "Perl interface to the Argon2 key derivation functions";
              license = final.lib.licenses.cc0;
            };
          };

          CryptPassphrase = final.perlPackages.buildPerlPackage {
            pname = "Crypt-Passphrase";
            version = "0.003";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/L/LE/LEONT/Crypt-Passphrase-0.003.tar.gz";
              sha256 = "685aa090f8179a86d6896212ccf8ccfde7a79cce857199bb14e2277a10d240ad";
            };
            meta = {
              description = "A module for managing passwords in a cryptographically agile manner";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          CryptPassphraseArgon2 = final.perlPackages.buildPerlPackage {
            pname = "Crypt-Passphrase-Argon2";
            version = "0.002";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/L/LE/LEONT/Crypt-Passphrase-Argon2-0.002.tar.gz";
              sha256 = "3906ff81697d13804ee21bd5ab78ffb1c4408b4822ce020e92ecf4737ba1f3a8";
            };
            propagatedBuildInputs = with final.perlPackages; [ CryptArgon2 CryptPassphrase ];
            meta = {
              description = "An Argon2 encoder for Crypt::Passphrase";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          DataRandom = final.perlPackages.buildPerlPackage {
            pname = "Data-Random";
            version = "0.13";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/B/BA/BAREFOOT/Data-Random-0.13.tar.gz";
              sha256 = "eb590184a8db28a7e49eab09e25f8650c33f1f668b6a472829de74a53256bfc0";
            };
            buildInputs = with final.perlPackages; [ FileShareDirInstall TestMockTime ];
            meta = {
              description = "Perl module to generate random data";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          DirSelf = final.perlPackages.buildPerlPackage {
            pname = "Dir-Self";
            version = "0.11";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/M/MA/MAUKE/Dir-Self-0.11.tar.gz";
              sha256 = "e251a51abc7d9ba3e708f73c2aa208e09d47a0c528d6254710fa78cc8d6885b5";
            };
            meta = {
              homepage = "https://github.com/mauke/Dir-Self";
              description = "A __DIR__ constant for the directory your source file is in";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          HashSharedMem = final.perlPackages.buildPerlModule {
            pname = "Hash-SharedMem";
            version = "0.005";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/Z/ZE/ZEFRAM/Hash-SharedMem-0.005.tar.gz";
              sha256 = "324776808602f7bdc44adaa937895365454029a926fa611f321c9bf6b940bb5e";
            };
            buildInputs = with final.perlPackages; [ ScalarString ];
            meta = {
              description = "Efficient shared mutable hash";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          PrometheusTiny = final.perlPackages.buildPerlPackage {
            pname = "Prometheus-Tiny";
            version = "0.007";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/R/RO/ROBN/Prometheus-Tiny-0.007.tar.gz";
              sha256 = "0ef8b226a2025cdde4df80129dd319aa29e884e653c17dc96f4823d985c028ec";
            };
            buildInputs = with final.perlPackages; [ HTTPMessage Plack TestException ];
            meta = {
              homepage = "https://github.com/robn/Prometheus-Tiny";
              description = "A tiny Prometheus client";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          PrometheusTinyShared = final.perlPackages.buildPerlPackage {
            pname = "Prometheus-Tiny-Shared";
            version = "0.023";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/R/RO/ROBN/Prometheus-Tiny-Shared-0.023.tar.gz";
              sha256 = "7c2c72397be5d8e4839d1bf4033c1800f467f2509689673c6419df48794f2abe";
            };
            buildInputs = with final.perlPackages; [ DataRandom HTTPMessage Plack TestDifferences TestException ];
            propagatedBuildInputs = with final.perlPackages; [ HashSharedMem JSONXS PrometheusTiny ];
            meta = {
              homepage = "https://github.com/robn/Prometheus-Tiny-Shared";
              description = "A tiny Prometheus client with a shared database behind it";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          ReadonlyX = final.perlPackages.buildPerlModule {
            pname = "ReadonlyX";
            version = "1.04";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/S/SA/SANKO/ReadonlyX-1.04.tar.gz";
              sha256 = "81bb97dba93ac6b5ccbce04a42c3590eb04557d75018773ee18d5a30fcf48188";
            };
            buildInputs = with final.perlPackages; [ ModuleBuildTiny TestFatal ];
            meta = {
              homepage = "https://github.com/sanko/readonly";
              description = "Faster facility for creating read-only scalars, arrays, hashes";
              license = final.lib.licenses.artistic2;
            };
          };

          TieHashMethod = final.perlPackages.buildPerlPackage {
            pname = "Tie-Hash-Method";
            version = "0.02";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/Y/YV/YVES/Tie-Hash-Method-0.02.tar.gz";
              sha256 = "d513fbb51413f7ca1e64a1bdce6194df7ec6076dea55066d67b950191eec32a9";
            };
            meta = {
              description = "Tied hash with specific methods overriden by callbacks";
              license = with final.lib.licenses; [ artistic1 ];
            };
          };

          Test2Harness = final.perlPackages.buildPerlPackage {
            pname = "Test2-Harness";
            version = "1.000042";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/E/EX/EXODIST/Test2-Harness-1.000042.tar.gz";
              sha256 = "aaf231a68af1a6ffd6a11188875fcf572e373e43c8285945227b9d687b43db2d";
            };

            checkPhase = ''
              patchShebangs ./t ./scripts/yath
              ./scripts/yath test -j $NIX_BUILD_CORES
            '';

            propagatedBuildInputs = with final.perlPackages; [ DataUUID Importer LongJump ScopeGuard TermTable Test2PluginMemUsage Test2PluginUUID Test2Suite gotofile ];
            meta = {
              description = "A new and improved test harness with better Test2 integration";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          Test2PluginMemUsage = prev.perlPackages.buildPerlPackage {
            pname = "Test2-Plugin-MemUsage";
            version = "0.002003";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/E/EX/EXODIST/Test2-Plugin-MemUsage-0.002003.tar.gz";
              sha256 = "5e0662d5a823ae081641f5ce82843111eec1831cd31f883a6c6de54afdf87c25";
            };
            buildInputs = with final.perlPackages; [ Test2Suite ];
            meta = {
              description = "Collect and display memory usage information";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          Test2PluginUUID = prev.perlPackages.buildPerlPackage {
            pname = "Test2-Plugin-UUID";
            version = "0.002001";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/E/EX/EXODIST/Test2-Plugin-UUID-0.002001.tar.gz";
              sha256 = "4c6c8d484d7153d8779dc155a992b203095b5c5aa1cfb1ee8bcedcd0601878c9";
            };
            buildInputs = with final.perlPackages;[ Test2Suite ];
            propagatedBuildInputs = with final.perlPackages; [ DataUUID ];
            meta = {
              description = "Use REAL UUIDs in Test2";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          LongJump = final.perlPackages.buildPerlPackage {
            pname = "Long-Jump";
            version = "0.000001";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/E/EX/EXODIST/Long-Jump-0.000001.tar.gz";
              sha256 = "d5d6456d86992b559d8f66fc90960f919292cd3803c13403faac575762c77af4";
            };
            buildInputs = with final.perlPackages; [ Test2Suite ];
            meta = {
              description = "Mechanism for returning to a specific point from a deeply nested stack";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          gotofile = final.perlPackages.buildPerlPackage {
            pname = "goto-file";
            version = "0.005";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/E/EX/EXODIST/goto-file-0.005.tar.gz";
              sha256 = "c6cdd5ee4a6cdcbdbf314d92a4f9985dbcdf9e4258048cae76125c052aa31f77";
            };
            buildInputs = with final.perlPackages; [ Test2Suite ];
            meta = {
              description = "Stop parsing the current file and move on to a different one";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          NetLDAPServer = prev.perlPackages.buildPerlPackage {
            pname = "Net-LDAP-Server";
            version = "0.43";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/A/AA/AAR/Net-LDAP-Server-0.43.tar.gz";
              sha256 = "0qmh3cri3fpccmwz6bhwp78yskrb3qmalzvqn0a23hqbsfs4qv6x";
            };
            propagatedBuildInputs = with final.perlPackages; [ NetLDAP ConvertASN1 ];
            meta = {
              description = "LDAP server side protocol handling";
              license = with final.lib.licenses; [ artistic1 ];
            };
          };

          NetLDAPSID = prev.perlPackages.buildPerlPackage {
            pname = "Net-LDAP-SID";
            version = "0.0001";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/K/KA/KARMAN/Net-LDAP-SID-0.001.tar.gz";
              sha256 = "1mnnpkmj8kpb7qw50sm8h4sd8py37ssy2xi5hhxzr5whcx0cvhm8";
            };
            meta = {
              description = "Active Directory Security Identifier manipulation";
              license = with final.lib.licenses; [ artistic2 ];
            };
          };

          NetLDAPServerTest = prev.perlPackages.buildPerlPackage {
            pname = "Net-LDAP-Server-Test";
            version = "0.22";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/K/KA/KARMAN/Net-LDAP-Server-Test-0.22.tar.gz";
              sha256 = "13idip7jky92v4adw60jn2gcc3zf339gsdqlnc9nnvqzbxxp285i";
            };
            propagatedBuildInputs = with final.perlPackages; [ NetLDAP NetLDAPServer TestMore DataDump NetLDAPSID ];
            meta = {
              description = "test Net::LDAP code";
              license = with final.lib.licenses; [ artistic1 ];
            };
          };

          CatalystAuthenticationStoreLDAP = prev.perlPackages.buildPerlPackage {
            pname = "Catalyst-Authentication-Store-LDAP";
            version = "1.016";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/I/IL/ILMARI/Catalyst-Authentication-Store-LDAP-1.016.tar.gz";
              sha256 = "0cm399vxqqf05cjgs1j5v3sk4qc6nmws5nfhf52qvpbwc4m82mq8";
            };
            propagatedBuildInputs = with final.perlPackages; [ NetLDAP CatalystPluginAuthentication ClassAccessorFast ];
            buildInputs = with final.perlPackages; [ TestMore TestMockObject TestException NetLDAPServerTest ];
            meta = {
              description = "Authentication from an LDAP Directory";
              license = with final.lib.licenses; [ artistic1 ];
            };
          };

          PerlCriticCommunity = prev.perlPackages.buildPerlModule {
            pname = "Perl-Critic-Community";
            version = "1.0.0";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/D/DB/DBOOK/Perl-Critic-Community-v1.0.0.tar.gz";
              sha256 = "311b775da4193e9de94cf5225e993cc54dd096ae1e7ef60738cdae1d9b8854e7";
            };
            buildInputs = with final.perlPackages; [ ModuleBuildTiny ];
            propagatedBuildInputs = with final.perlPackages; [ PPI PathTiny PerlCritic PerlCriticPolicyVariablesProhibitLoopOnHash PerlCriticPulp ];
            meta = {
              homepage = "https://github.com/Grinnz/Perl-Critic-Freenode";
              description = "Community-inspired Perl::Critic policies";
              license = final.lib.licenses.artistic2;
            };
          };

          PerlCriticPolicyVariablesProhibitLoopOnHash = prev.perlPackages.buildPerlPackage {
            pname = "Perl-Critic-Policy-Variables-ProhibitLoopOnHash";
            version = "0.008";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/X/XS/XSAWYERX/Perl-Critic-Policy-Variables-ProhibitLoopOnHash-0.008.tar.gz";
              sha256 = "12f5f0be96ea1bdc7828058577bd1c5c63ca23c17fac9c3709452b3dff5b84e0";
            };
            propagatedBuildInputs = with final.perlPackages; [ PerlCritic ];
            meta = {
              description = "Don't write loops on hashes, only on keys and values of hashes";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          PerlCriticPulp = prev.perlPackages.buildPerlPackage {
            pname = "Perl-Critic-Pulp";
            version = "99";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/K/KR/KRYDE/Perl-Critic-Pulp-99.tar.gz";
              sha256 = "b8fda842fcbed74d210257c0a284b6dc7b1d0554a47a3de5d97e7d542e23e7fe";
            };
            propagatedBuildInputs = with final.perlPackages; [ IOString ListMoreUtils PPI PerlCritic PodMinimumVersion ];
            meta = {
              homepage = "http://user42.tuxfamily.org/perl-critic-pulp/index.html";
              description = "Some add-on policies for Perl::Critic";
              license = final.lib.licenses.gpl3Plus;
            };
          };

          PodMinimumVersion = prev.perlPackages.buildPerlPackage {
            pname = "Pod-MinimumVersion";
            version = "50";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/K/KR/KRYDE/Pod-MinimumVersion-50.tar.gz";
              sha256 = "0bd2812d9aacbd99bb71fa103a4bb129e955c138ba7598734207dc9fb67b5a6f";
            };
            propagatedBuildInputs = with final.perlPackages; [ IOString PodParser ];
            meta = {
              homepage = "http://user42.tuxfamily.org/pod-minimumversion/index.html";
              description = "Determine minimum Perl version of POD directives";
              license = final.lib.licenses.free;
            };
          };

          StringCompareConstantTime = final.perlPackages.buildPerlPackage {
            pname = "String-Compare-ConstantTime";
            version = "0.321";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/F/FR/FRACTAL/String-Compare-ConstantTime-0.321.tar.gz";
              sha256 = "0b26ba2b121d8004425d4485d1d46f59001c83763aa26624dff6220d7735d7f7";
            };
            meta = {
              description = "Timing side-channel protected string compare";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

          UUID4Tiny = final.perlPackages.buildPerlPackage {
            pname = "UUID4-Tiny";
            version = "0.002";
            src = final.fetchurl {
              url = "mirror://cpan/authors/id/C/CV/CVLIBRARY/UUID4-Tiny-0.002.tar.gz";
              sha256 = "e7535b31e386d432dec7adde214348389e1d5cf753e7ed07f1ae04c4360840cf";
            };
            meta = {
              description = "Cryptographically secure v4 UUIDs for Linux x64";
              license = with final.lib.licenses; [ artistic1 gpl1Plus ];
            };
          };

        };

        hydra = with final; let
          perlDeps = buildEnv {
            name = "hydra-perl-deps";
            paths = with perlPackages; lib.closePropagation
              [
                AuthenSASL
                CatalystActionREST
                CatalystAuthenticationStoreDBIxClass
                CatalystAuthenticationStoreLDAP
                CatalystDevel
                CatalystPluginAccessLog
                CatalystPluginAuthorizationRoles
                CatalystPluginCaptcha
                CatalystPluginPrometheusTiny
                CatalystPluginSessionStateCookie
                CatalystPluginSessionStoreFastMmap
                CatalystPluginStackTrace
                CatalystPluginUnicodeEncoding
                CatalystTraitForRequestProxyBase
                CatalystViewDownload
                CatalystViewJSON
                CatalystViewTT
                CatalystXRoleApplicator
                CatalystXScriptServerStarman
                CryptPassphrase
                CryptPassphraseArgon2
                CryptRandPasswd
                DataDump
                DateTime
                DBDPg
                DBDSQLite
                DigestSHA1
                EmailMIME
                EmailSender
                FileSlurper
                FileWhich
                final.nix.perl-bindings
                git
                IOCompress
                IPCRun
                IPCRun3
                JSON
                JSONMaybeXS
                JSONXS
                ListSomeUtils
                LWP
                LWPProtocolHttps
                ModulePluggable
                NetAmazonS3
                NetPrometheus
                NetStatsd
                PadWalker
                ParallelForkManager
                PerlCriticCommunity
                PrometheusTinyShared
                ReadonlyX
                SetScalar
                SQLSplitStatement
                Starman
                StringCompareConstantTime
                SysHostnameLong
                TermSizeAny
                TermReadKey
                Test2Harness
                TestMore
                TestPostgreSQL
                TextDiff
                TextTable
                UUID4Tiny
                YAML
                XMLSimple
              ];
          };

        in
        stdenv.mkDerivation {

          name = "hydra-${version}";

          src = self;

          buildInputs =
            [
              makeWrapper
              autoconf
              automake
              libtool
              unzip
              nukeReferences
              pkgconfig
              libpqxx
              gitAndTools.topGit
              mercurial
              darcs
              subversion
              breezy
              openssl
              bzip2
              libxslt
              final.nix
              perlDeps
              perl
              mdbook
              pixz
              boost
              postgresql_13
              (if lib.versionAtLeast lib.version "20.03pre"
              then nlohmann_json
              else nlohmann_json.override { multipleHeaders = true; })
              prometheus-cpp
            ];

          checkInputs = [
            cacert
            # FIXME: foreman is broken on all nix/nixpkgs pin, up to and
            # including 2.7.0
            newNixpkgs.legacyPackages.${final.system}.foreman
            glibcLocales
            libressl.nc
            openldap
            python3
          ];

          hydraPath = lib.makeBinPath (
            [
              subversion
              openssh
              final.nix
              coreutils
              findutils
              pixz
              gzip
              bzip2
              lzma
              gnutar
              unzip
              git
              gitAndTools.topGit
              mercurial
              darcs
              gnused
              breezy
            ] ++ lib.optionals stdenv.isLinux [ rpm dpkg cdrkit ]
          );

          OPENLDAP_ROOT = openldap;

          shellHook = ''
            pushd $(git rev-parse --show-toplevel) >/dev/null

            PATH=$(pwd)/src/hydra-evaluator:$(pwd)/src/script:$(pwd)/src/hydra-eval-jobs:$(pwd)/src/hydra-queue-runner:$PATH
            PERL5LIB=$(pwd)/src/lib:$PERL5LIB
            export HYDRA_HOME="$(pwd)/src/"
            mkdir -p .hydra-data
            export HYDRA_DATA="$(pwd)/.hydra-data"
            export HYDRA_DBI='dbi:Pg:dbname=hydra;host=localhost;port=64444'

            popd >/dev/null
          '';

          preConfigure = "autoreconf -vfi";

          NIX_LDFLAGS = [ "-lpthread" ];

          enableParallelBuilding = true;

          doCheck = true;

          preCheck = ''
            patchShebangs .
            export LOGNAME=''${LOGNAME:-foo}
            # set $HOME for bzr so it can create its trace file
            export HOME=$(mktemp -d)
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
                    --set NIX_RELEASE ${final.nix.name or "unknown"}
            done
          '';

          dontStrip = true;

          meta.description = "Build of Hydra on ${system}";
          passthru = { inherit perlDeps; inherit (final) nix; };
        };
      };

      hydraJobs = {

        build.x86_64-linux = packages.x86_64-linux.hydra;

        manual =
          pkgs.runCommand "hydra-manual-${version}" { }
            ''
              mkdir -p $out/share
              cp -prvd ${pkgs.hydra}/share/doc $out/share/

              mkdir $out/nix-support
              echo "doc manual $out/share/doc/hydra" >> $out/nix-support/hydra-build-products
            '';

        tests.install.x86_64-linux =
          with import (nixpkgs + "/nixos/lib/testing-python.nix") { system = "x86_64-linux"; };
          simpleTest {
            machine = hydraServer;
            testScript =
              ''
                machine.wait_for_job("hydra-init")
                machine.wait_for_job("hydra-server")
                machine.wait_for_job("hydra-evaluator")
                machine.wait_for_job("hydra-queue-runner")
                machine.wait_for_open_port("3000")
                machine.succeed("curl --fail http://localhost:3000/")
              '';
          };

        tests.notifications.x86_64-linux =
          with import (nixpkgs + "/nixos/lib/testing-python.nix") { system = "x86_64-linux"; };
          simpleTest {
            machine = { pkgs, ... }: {
              imports = [ hydraServer ];
              services.hydra-dev.extraConfig = ''
                <influxdb>
                  url = http://127.0.0.1:8086
                  db = hydra
                </influxdb>
              '';
              services.influxdb.enable = true;
            };
            testScript = ''
              machine.wait_for_job("hydra-init")

              # Create an admin account and some other state.
              machine.succeed(
                  """
                      su - hydra -c "hydra-create-user root --email-address 'alice@example.org' --password foobar --role admin"
                      mkdir /run/jobset
                      chmod 755 /run/jobset
                      cp ${./t/jobs/api-test.nix} /run/jobset/default.nix
                      chmod 644 /run/jobset/default.nix
                      chown -R hydra /run/jobset
              """
              )

              # Wait until InfluxDB can receive web requests
              machine.wait_for_job("influxdb")
              machine.wait_for_open_port("8086")

              # Create an InfluxDB database where hydra will write to
              machine.succeed(
                  "curl -XPOST 'http://127.0.0.1:8086/query' "
                  + "--data-urlencode 'q=CREATE DATABASE hydra'"
              )

              # Wait until hydra-server can receive HTTP requests
              machine.wait_for_job("hydra-server")
              machine.wait_for_open_port("3000")

              # Setup the project and jobset
              machine.succeed(
                  "su - hydra -c 'perl -I ${pkgs.hydra.perlDeps}/lib/perl5/site_perl ${./t/setup-notifications-jobset.pl}' >&2"
              )

              # Wait until hydra has build the job and
              # the InfluxDBNotification plugin uploaded its notification to InfluxDB
              machine.wait_until_succeeds(
                  "curl -s -H 'Accept: application/csv' "
                  + "-G 'http://127.0.0.1:8086/query?db=hydra' "
                  + "--data-urlencode 'q=SELECT * FROM hydra_build_status' | grep success"
              )
            '';
          };

        tests.gitea.x86_64-linux =
          with import (nixpkgs + "/nixos/lib/testing-python.nix") { system = "x86_64-linux"; };
          makeTest {
            machine = { pkgs, ... }: {
              imports = [ hydraServer ];
              services.hydra-dev.extraConfig = ''
                <gitea_authorization>
                root=d7f16a3412e01a43a414535b16007c6931d3a9c7
                </gitea_authorization>
              '';
              nix = {
                distributedBuilds = true;
                buildMachines = [{
                  hostName = "localhost";
                  systems = [ "x86_64-linux" ];
                }];
                binaryCaches = [ ];
              };
              services.gitea = {
                enable = true;
                database.type = "postgres";
                disableRegistration = true;
                httpPort = 3001;
              };
              services.openssh.enable = true;
              environment.systemPackages = with pkgs; [ gitea git jq gawk ];
              networking.firewall.allowedTCPPorts = [ 3000 ];
            };
            skipLint = true;
            testScript =
              let
                scripts.mktoken = pkgs.writeText "token.sql" ''
                  INSERT INTO access_token (id, uid, name, created_unix, updated_unix, token_hash, token_salt, token_last_eight) VALUES (1, 1, 'hydra', 1617107360, 1617107360, 'a930f319ca362d7b49a4040ac0af74521c3a3c3303a86f327b01994430672d33b6ec53e4ea774253208686c712495e12a486', 'XRjWE9YW0g', '31d3a9c7');
                '';

                scripts.git-setup = pkgs.writeShellScript "setup.sh" ''
                  set -x
                  mkdir -p /tmp/repo $HOME/.ssh
                  cat ${snakeoilKeypair.privkey} > $HOME/.ssh/privk
                  chmod 0400 $HOME/.ssh/privk
                  git -C /tmp/repo init
                  cp ${smallDrv} /tmp/repo/jobset.nix
                  git -C /tmp/repo add .
                  git config --global user.email test@localhost
                  git config --global user.name test
                  git -C /tmp/repo commit -m 'Initial import'
                  git -C /tmp/repo remote add origin gitea@machine:root/repo
                  GIT_SSH_COMMAND='ssh -i $HOME/.ssh/privk -o StrictHostKeyChecking=no' \
                    git -C /tmp/repo push origin master
                  git -C /tmp/repo log >&2
                '';

                scripts.hydra-setup = pkgs.writeShellScript "hydra.sh" ''
                  set -x
                  su -l hydra -c "hydra-create-user root --email-address \
                    'alice@example.org' --password foobar --role admin"

                  URL=http://localhost:3000
                  USERNAME="root"
                  PASSWORD="foobar"
                  PROJECT_NAME="trivial"
                  JOBSET_NAME="trivial"
                  mycurl() {
                    curl --referer $URL -H "Accept: application/json" \
                      -H "Content-Type: application/json" $@
                  }

                  cat >data.json <<EOF
                  { "username": "$USERNAME", "password": "$PASSWORD" }
                  EOF
                  mycurl -X POST -d '@data.json' $URL/login -c hydra-cookie.txt

                  cat >data.json <<EOF
                  {
                    "displayname":"Trivial",
                    "enabled":"1",
                    "visible":"1"
                  }
                  EOF
                  mycurl --silent -X PUT $URL/project/$PROJECT_NAME \
                    -d @data.json -b hydra-cookie.txt

                  cat >data.json <<EOF
                  {
                    "description": "Trivial",
                    "checkinterval": "60",
                    "enabled": "1",
                    "visible": "1",
                    "keepnr": "1",
                    "enableemail": true,
                    "emailoverride": "hydra@localhost",
                    "type": 0,
                    "nixexprinput": "git",
                    "nixexprpath": "jobset.nix",
                    "inputs": {
                      "git": {"value": "http://localhost:3001/root/repo.git", "type": "git"},
                      "gitea_repo_name": {"value": "repo", "type": "string"},
                      "gitea_repo_owner": {"value": "root", "type": "string"},
                      "gitea_status_repo": {"value": "git", "type": "string"},
                      "gitea_http_url": {"value": "http://localhost:3001", "type": "string"}
                    }
                  }
                  EOF

                  mycurl --silent -X PUT $URL/jobset/$PROJECT_NAME/$JOBSET_NAME \
                    -d @data.json -b hydra-cookie.txt
                '';

                api_token = "d7f16a3412e01a43a414535b16007c6931d3a9c7";

                snakeoilKeypair = {
                  privkey = pkgs.writeText "privkey.snakeoil" ''
                    -----BEGIN EC PRIVATE KEY-----
                    MHcCAQEEIHQf/khLvYrQ8IOika5yqtWvI0oquHlpRLTZiJy5dRJmoAoGCCqGSM49
                    AwEHoUQDQgAEKF0DYGbBwbj06tA3fd/+yP44cvmwmHBWXZCKbS+RQlAKvLXMWkpN
                    r1lwMyJZoSGgBHoUahoYjTh9/sJL7XLJtA==
                    -----END EC PRIVATE KEY-----
                  '';

                  pubkey = pkgs.lib.concatStrings [
                    "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHA"
                    "yNTYAAABBBChdA2BmwcG49OrQN33f/sj+OHL5sJhwVl2Qim0vkUJQCry1zFpKTa"
                    "9ZcDMiWaEhoAR6FGoaGI04ff7CS+1yybQ= sakeoil"
                  ];
                };

                smallDrv = pkgs.writeText "jobset.nix" ''
                  { trivial = builtins.derivation {
                      name = "trivial";
                      system = "x86_64-linux";
                      builder = "/bin/sh";
                      allowSubstitutes = false;
                      preferLocalBuild = true;
                      args = ["-c" "echo success > $out; exit 0"];
                    };
                   }
                '';
              in
              ''
                import json

                machine.start()
                machine.wait_for_unit("multi-user.target")
                machine.wait_for_open_port(3000)
                machine.wait_for_open_port(3001)

                machine.succeed(
                    "su -l gitea -c 'GITEA_WORK_DIR=/var/lib/gitea gitea admin user create "
                    + "--username root --password root --email test@localhost'"
                )
                machine.succeed("su -l postgres -c 'psql gitea < ${scripts.mktoken}'")

                machine.succeed(
                    "curl --fail -X POST http://localhost:3001/api/v1/user/repos "
                    + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
                    + f"-H 'Authorization: token ${api_token}'"
                    + ' -d \'{"auto_init":false, "description":"string", "license":"mit", "name":"repo", "private":false}\'''
                )

                machine.succeed(
                    "curl --fail -X POST http://localhost:3001/api/v1/user/keys "
                    + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
                    + f"-H 'Authorization: token ${api_token}'"
                    + ' -d \'{"key":"${snakeoilKeypair.pubkey}","read_only":true,"title":"SSH"}\'''
                )

                machine.succeed(
                    "${scripts.git-setup}"
                )

                machine.succeed(
                    "${scripts.hydra-setup}"
                )

                machine.wait_until_succeeds(
                    'curl -Lf -s http://localhost:3000/build/1 -H "Accept: application/json" '
                    + '|  jq .buildstatus | xargs test 0 -eq'
                )

                data = machine.succeed(
                    'curl -Lf -s "http://localhost:3001/api/v1/repos/root/repo/statuses/$(cd /tmp/repo && git show | head -n1 | awk "{print \\$2}")" '
                    + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
                    + f"-H 'Authorization: token ${api_token}'"
                )

                response = json.loads(data)

                assert len(response) == 2, "Expected exactly two status updates for latest commit!"
                assert response[0]['status'] == "success", "Expected latest status to be success!"
                assert response[1]['status'] == "pending", "Expected first status to be pending!"

                machine.shutdown()
              '';
          };

        tests.validate-openapi = pkgs.runCommand "validate-openapi"
          { buildInputs = [ pkgs.openapi-generator-cli ]; }
          ''
            openapi-generator-cli validate -i ${./hydra-api.yaml}
            touch $out
          '';

        container = nixosConfigurations.container.config.system.build.toplevel;
      };

      checks.x86_64-linux.build = hydraJobs.build.x86_64-linux;
      checks.x86_64-linux.install = hydraJobs.tests.install.x86_64-linux;
      checks.x86_64-linux.validate-openapi = hydraJobs.tests.validate-openapi;

      packages.x86_64-linux.hydra = pkgs.hydra;
      defaultPackage.x86_64-linux = pkgs.hydra;

      nixosModules.hydra = {
        imports = [ ./hydra-module.nix ];
        nixpkgs.overlays = [ self.overlay nix.overlay ];
      };

      nixosModules.hydraTest = {
        imports = [ self.nixosModules.hydra ];

        services.hydra-dev.enable = true;
        services.hydra-dev.hydraURL = "http://hydra.example.org";
        services.hydra-dev.notificationSender = "admin@hydra.example.org";

        systemd.services.hydra-send-stats.enable = false;

        services.postgresql.enable = true;
        services.postgresql.package = pkgs.postgresql_11;

        # The following is to work around the following error from hydra-server:
        #   [error] Caught exception in engine "Cannot determine local time zone"
        time.timeZone = "UTC";

        nix.extraOptions = ''
          allowed-uris = https://github.com/
        '';
      };

      nixosModules.hydraProxy = {
        services.httpd = {
          enable = true;
          adminAddr = "hydra-admin@example.org";
          extraConfig = ''
            <Proxy *>
              Order deny,allow
              Allow from all
            </Proxy>

            ProxyRequests     Off
            ProxyPreserveHost On
            ProxyPass         /apache-errors !
            ErrorDocument 503 /apache-errors/503.html
            ProxyPass         /       http://127.0.0.1:3000/ retry=5 disablereuse=on
            ProxyPassReverse  /       http://127.0.0.1:3000/
          '';
        };
      };

      nixosConfigurations.container = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules =
          [
            self.nixosModules.hydraTest
            self.nixosModules.hydraProxy
            {
              system.configurationRevision = self.rev;

              boot.isContainer = true;
              networking.useDHCP = false;
              networking.firewall.allowedTCPPorts = [ 80 ];
              networking.hostName = "hydra";

              services.hydra-dev.useSubstitutes = true;
            }
          ];
      };

    };
}

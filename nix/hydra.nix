{ pkgs, hydraSrc, version, system }:
with pkgs;
let
  perlDeps = buildEnv {
    name = "hydra-perl-deps";
    paths = with perlPackages; lib.closePropagation [
      ModulePluggable
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
    ];
  };
in
    stdenv.mkDerivation {

      name = "hydra-${version}";
      src = hydraSrc;
      buildInputs =
        [ makeWrapper autoconf automake libtool unzip nukeReferences pkgconfig libpqxx
        gitAndTools.topGit mercurial darcs subversion bazaar openssl bzip2 libxslt
        perlDeps perl nix
        boost
        postgresql95
        (if lib.versionAtLeast lib.version "20.03pre"
        then nlohmann_json
        else nlohmann_json.override { multipleHeaders = true; })
      ];

      checkInputs = [
        foreman
      ];

      hydraPath = lib.makeBinPath (
        [ subversion openssh nix coreutils findutils pixz
        gzip bzip2 lzma gnutar unzip git gitAndTools.topGit mercurial darcs gnused bazaar
      ] ++ lib.optionals stdenv.isLinux [ rpm dpkg cdrkit ] );

      configureFlags = [ "--with-docbook-xsl=${docbook_xsl}/xml/xsl/docbook" ];

      shellHook = ''
            PATH=$(pwd)/src/hydra-evaluator:$(pwd)/src/script:$(pwd)/src/hydra-eval-jobs:$(pwd)/src/hydra-queue-runner:$PATH
            PERL5LIB=$(pwd)/src/lib:$PERL5LIB
            export HYDRA_HOME="src/"
            mkdir -p .hydra-data
            export HYDRA_DATA="$(pwd)/.hydra-data"
            export HYDRA_DBI='dbi:Pg:dbname=hydra;host=localhost;port=64444'
      '';

      preConfigure = "autoreconf -vfi";

      NIX_LDFLAGS = [ "-lpthread" ];

      enableParallelBuilding = true;

      doCheck = true;

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
      '';

      dontStrip = true;

      meta.description = "Build of Hydra on ${system}";
      passthru.perlDeps = perlDeps;
    }

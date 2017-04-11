{ stdenv
, hydraSrc ? { outPath = ./.; revCount = 1234; rev = "abcdef"; }
, version ? builtins.readFile ./version + "." + toString hydraSrc.revCount + "." + hydraSrc.rev
, makeWrapper, libtool, unzip, nukeReferences, sqlite, libpqxx
, guile ? null
, perl, nix, postgresql92, perlPackages, openssh, buildEnv
, autoreconfHook, pkgconfig, topGit, mercurial, darcs, subversion, bazaar
, openssl, bzip2, libxslt, docbook_xsl, coreutils, findutils, pixz, gzip
, lzma, gnutar, git, gnused, rpm, dpkg, cdrkit, boehmgc, aws-sdk-cpp
}: assert builtins.compareVersions "6" stdenv.cc.cc.version < 1;
let perlDeps = buildEnv {
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
          aws-sdk-cpp
        ];
    };
in stdenv.mkDerivation {
  name = "hydra-${version}";
  src = hydraSrc;
  buildInputs =
    [ makeWrapper autoreconfHook libtool unzip nukeReferences pkgconfig sqlite libpqxx
      topGit mercurial darcs subversion bazaar openssl bzip2 libxslt
      guile # optional, for Guile + Guix support
      perlDeps perl nix
      postgresql92 # for running the tests
    ];

  hydraPath = stdenv.lib.makeBinPath (
    [ sqlite subversion openssh nix coreutils findutils pixz
      gzip bzip2 lzma gnutar unzip git topGit mercurial darcs gnused bazaar
    ] ++ stdenv.lib.optionals stdenv.isLinux [ rpm dpkg cdrkit ] );

  configureFlags = [ "--with-docbook-xsl=${docbook_xsl}/xml/xsl/docbook" ];


  preHook = ''
    PATH=$(pwd)/src/hydra-evaluator:$(pwd)/src/script:$(pwd)/src/hydra-eval-jobs:$(pwd)/src/hydra-queue-runner:$PATH
    PERL5LIB=$(pwd)/src/lib:$PERL5LIB;
  '';

  preCheck = ''
    patchShebangs .
    export LOGNAME=${LOGNAME:-foo}
  '';

  postInstall = ''
    mkdir -p $out/nix-support

    for i in $out/bin/*; do #*/
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

  passthru.perlDeps = perlDeps;
}

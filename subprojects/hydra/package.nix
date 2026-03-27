{
  stdenv,
  lib,
  version,
  releaseVersion,

  rawSrc,

  buildEnv,

  perlPackages,

  nixComponents,
  git,

  makeWrapper,
  meson,
  ninja,
  nukeReferences,
  pkg-config,

  unzip,
  libpqxx,
  openssl,
  bzip2,
  libxslt,
  perl,
  pixz,
  boost,
  nlohmann_json,
  prometheus-cpp,

  openssh,
  coreutils,
  findutils,
  gzip,
  xz,
  gnutar,
  gnused,
  nix-eval-jobs,

  subversion,
  top-git,
  mercurial,
  darcs,
  breezy,

  rpm,
  dpkg,
  cdrkit,

}:

let
  perlDeps = buildEnv {
    name = "hydra-perl-deps";
    paths = lib.closePropagation (
      [
        nixComponents.nix-perl-bindings
        git
      ]
      ++ (with perlPackages; [
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
        DBIxClassHelpers
        DigestSHA1
        EmailMIME
        EmailSender
        FileCopyRecursive
        FileLibMagic
        FileSlurper
        FileWhich
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
        NumberBytesHuman
        PadWalker
        ParallelForkManager

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
        TestPostgreSQL
        TextDiff
        TextTable
        UUID4Tiny
        YAML
        XMLSimple
      ])
    );
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "hydra";
  version = releaseVersion;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../subprojects/hydra
      ../../version.txt
    ];
  };

  sourceRoot = "${finalAttrs.src.name}/subprojects/hydra";

  outputs = [ "out" ];

  strictDeps = true;

  nativeBuildInputs = [
    makeWrapper
    meson
    ninja
    nukeReferences
    pkg-config
    perlDeps
    perl
    unzip
  ];

  buildInputs = [
    libpqxx
    openssl
    libxslt
    nixComponents.nix-util
    nixComponents.nix-store
    nixComponents.nix-main
    perlDeps
    perl
    boost
    nlohmann_json
    prometheus-cpp
  ];

  hydraPath = lib.makeBinPath (
    [
      subversion
      openssh
      nixComponents.nix-cli
      coreutils
      findutils
      pixz
      gzip
      bzip2
      xz
      gnutar
      unzip
      git
      top-git
      mercurial
      darcs
      gnused
      breezy
      nix-eval-jobs
    ]
    ++ lib.optionals stdenv.isLinux [
      rpm
      dpkg
      cdrkit
    ]
  );

  mesonBuildType = "release";

  postPatch = ''
    patchShebangs .
  '';

  doCheck = false;

  postInstall = ''
    mkdir -p $out/nix-support

    for i in $out/bin/*; do
        read -n 4 chars < $i
        if [[ $chars =~ ELF ]]; then continue; fi
        wrapProgram $i \
            --prefix PERL5LIB ':' $out/libexec/hydra/lib:$PERL5LIB \
            --prefix PATH ':' $out/bin:$hydraPath \
            --set HYDRA_RELEASE ${releaseVersion} \
            --set HYDRA_HOME $out/libexec/hydra \
            --set NIX_RELEASE ${nixComponents.nix-cli.name or "unknown"} \
            --set NIX_EVAL_JOBS_RELEASE ${nix-eval-jobs.name or "unknown"}
    done
  '';

  dontStrip = true;

  meta.description = "Build of Hydra on ${stdenv.system}";
  passthru = {
    inherit perlDeps;
    nix = nixComponents.nix-cli;
  };
})

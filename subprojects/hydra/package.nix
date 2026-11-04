{
  stdenv,
  lib,
  version,
  releaseVersion,

  rawSrc,

  buildEnv,

  perlPackages,

  nixComponents,
  nix-perl,
  git,

  meson,
  ninja,
  nukeReferences,

  unzip,
  perl,
}:

let
  perlDeps = buildEnv {
    name = "hydra-perl-deps";
    paths = lib.closePropagation (
      [
        nix-perl
        git
      ]
      ++ (with perlPackages; [
        AuthenSASL
        CacheFastMmap
        CatalystActionREST
        CatalystAuthenticationStoreDBIxClass
        CatalystAuthenticationStoreLDAP
        CatalystDevel
        CatalystPluginAccessLog
        CatalystPluginAuthorizationRoles
        CatalystPluginCaptcha
        CatalystPluginCache
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
        CryptJWT
        CryptPassphrase
        CryptPassphraseArgon2
        CryptRandPasswd
        CryptURandom
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
        URIdb
        UUIDURandom
        WWWMechanize
        YAML
        XMLSimple
      ])
    );
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "hydra-perl";
  version = releaseVersion;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../subprojects/hydra/lib
      ../../subprojects/hydra/Makefile.PL
      ../../subprojects/hydra/meson.build
      ../../subprojects/hydra/package.nix
      ../../subprojects/hydra/root
      ../../subprojects/hydra/script
      ../../subprojects/hydra/sql/hydra.sql
      ../../subprojects/hydra/sql/meson.build
      ../../subprojects/hydra/sql/migrations
      ../../subprojects/hydra/sql/test.sql
      ../../subprojects/hydra/sql/update-dbix.pl
      ../../subprojects/hydra/sql/update-dbix-harness.sh
      ../../subprojects/hydra/ttf
      ../../subprojects/hydra/version.txt
      ../../version.txt
    ];
  };

  sourceRoot = "${finalAttrs.src.name}/subprojects/hydra";

  outputs = [ "out" ];

  strictDeps = true;

  nativeBuildInputs = [
    meson
    ninja
    nukeReferences
    perlDeps
    perl
    unzip
  ];

  buildInputs = [
    perlDeps
    perl
  ];

  mesonBuildType = "release";

  postPatch = ''
    patchShebangs .
  '';

  doCheck = false;

  # The scripts can't run as installed: they need `PERL5LIB`, `HYDRA_HOME`
  # and the tools they call on `PATH`. `wrappers.nix` provides those, and
  # gives each script only the tools it uses. They are kept out of `bin`
  # so that nothing runs them unwrapped by accident.
  postInstall = ''
    mkdir -p $out/nix-support
    mv $out/bin $out/libexec/hydra/script
  '';

  dontStrip = true;

  meta.description = "Hydra's Perl code and web assets, unwrapped, on ${stdenv.system}";
  passthru = {
    inherit perlDeps;
    nix = nixComponents.nix-cli;
  };
})

{
  stdenv,
  lib,
  version,
  releaseVersion,

  rawSrc,

  perlPackages,

  nixComponents,
  nix-perl,

  meson,
  ninja,
  nukeReferences,

  unzip,
  perl,
}:

let
  # The Perl modules Hydra's Perl uses, as a plain list. What they need in
  # turn they propagate, which Perl's setup hook follows when these are build
  # inputs, and `perl.withPackages` follows for the wrappers. Being a list
  # also keeps `nix-perl`, which is ours, visible as one of Hydra's components,
  # so the dev shell, which builds it from the tree, can leave it out, as
  # Nix's does.
  perlDeps = [
    nix-perl
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
  ]);
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
    perl
    unzip
  ]
  ++ perlDeps;

  buildInputs = [ perl ] ++ perlDeps;

  mesonBuildType = "release";

  postPatch = ''
    patchShebangs .
  '';

  doCheck = false;

  dontStrip = true;

  meta.description = "Hydra's Perl code and web assets, unwrapped, on ${stdenv.system}";
  passthru = {
    inherit perlDeps;
    nix = nixComponents.nix-cli;
  };
})

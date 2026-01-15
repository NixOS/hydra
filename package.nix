{ stdenv
, lib
, fileset

, rawSrc

, buildEnv

, perlPackages

, nixComponents
, git

, makeWrapper
, meson
, ninja
, nukeReferences
, pkg-config
, mdbook

, unzip
, libpqxx
, top-git
, mercurial
, darcs
, subversion
, breezy
, openssl
, bzip2
, libxslt
, perl
, pixz
, boost
, postgresql_17
, nlohmann_json
, prometheus-cpp

, cacert
, foreman
, glibcLocales
, libressl
, openldap
, python3

, openssh
, coreutils
, findutils
, gzip
, xz
, gnutar
, gnused
, nix-eval-jobs

, rpm
, dpkg
, cdrkit

, rustPackages
, libsodium
, zlib
, protobuf
}:

let
  perlDeps = buildEnv {
    name = "hydra-perl-deps";
    paths = lib.closePropagation
      ([
        nixComponents.nix-perl-bindings
        git
      ] ++ (with perlPackages; [
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
        TestPostgreSQL
        TextDiff
        TextTable
        UUID4Tiny
        YAML
        XMLSimple
      ]));
  };

  version = "${builtins.readFile ./version.txt}.${builtins.substring 0 8 (rawSrc.lastModifiedDate or "19700101")}.${rawSrc.shortRev or "DIRTY"}";
in
stdenv.mkDerivation {
  pname = "hydra";
  inherit version;

  src = fileset.toSource {
    root = ./.;
    fileset = fileset.unions [
      ./.cargo
      ./.perlcriticrc
      ./.sqlx
      ./Cargo.lock
      ./Cargo.toml
      ./doc
      ./meson.build
      ./meson_options.txt
      ./nixos-modules
      ./src
      ./t
      ./version.txt
    ];
  };

  outputs = [ "out" "doc" ];

  strictDeps = true;

  cargoDeps = rustPackages.rustPlatform.importCargoLock {
    lockFile = ./Cargo.lock;
    outputHashes = {
      "nix-diff-0.1.0" = "sha256-heUqcAnGmMogyVXskXc4FMORb8ZaK6vUX+mMOpbfSUw=";
    };
  };

  nativeBuildInputs = [
    makeWrapper
    meson
    ninja
    nukeReferences
    pkg-config
    mdbook
    nixComponents.nix-cli
    perlDeps
    perl
    unzip
    protobuf
    rustPackages.cargo
    rustPackages.clippy
    rustPackages.rustPlatform.cargoSetupHook
    rustPackages.rustc
    rustPackages.rustfmt
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
    libsodium
    zlib
    protobuf
  ];

  nativeCheckInputs = [
    bzip2
    darcs
    foreman
    top-git
    mercurial
    subversion
    breezy
    openldap
    postgresql_17
    pixz
    nix-eval-jobs
  ];

  checkInputs = [
    cacert
    glibcLocales
    libressl.nc
    python3
    nixComponents.nix-cli
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
    ] ++ lib.optionals stdenv.isLinux [ rpm dpkg cdrkit ]
  );

  OPENLDAP_ROOT = openldap;
  NIX_CFLAGS_COMPILE = "-Wno-error";

  mesonBuildType = "release";

  postPatch = ''
    patchShebangs .
  '';

  shellHook = ''
    pushd $(git rev-parse --show-toplevel) >/dev/null

    PATH=$(pwd)/build/src/hydra-evaluator:$(pwd)/src/script:$(pwd)/build/src:$PATH
    PERL5LIB=$(pwd)/src/lib:$PERL5LIB
    export HYDRA_HOME="$(pwd)/src/"
    mkdir -p .hydra-data
    export HYDRA_DATA="$(pwd)/.hydra-data"
    export HYDRA_DBI='dbi:Pg:dbname=hydra;host=localhost;port=64444'

    popd >/dev/null
  '';

  doCheck = true;

  mesonCheckFlags = [ "--verbose" ];

  preCheck = ''
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
}

{ stdenv
, lib
, fileset

, rawSrc

, buildEnv

, perlPackages

, nix
, git

, makeWrapper
, autoreconfHook
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
, postgresql_13
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

, rpm
, dpkg
, cdrkit
}:

let
  perlDeps = buildEnv {
    name = "hydra-perl-deps";
    paths = lib.closePropagation
      ([
        nix.perl-bindings
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
        DigestSHA1
        EmailMIME
        EmailSender
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
stdenv.mkDerivation (finalAttrs: {
  pname = "hydra";
  inherit version;

  src = fileset.toSource {
    root = ./.;
    fileset = fileset.unions ([
      ./version.txt
      ./configure.ac
      ./Makefile.am
      ./src
      ./doc
      ./nixos-modules/hydra.nix
      # These are always needed to appease Automake
      ./t/Makefile.am
      ./t/jobs/config.nix.in
      ./t/jobs/declarative/project.json.in
    ] ++ lib.optionals finalAttrs.doCheck [
      ./t
      ./.perlcriticrc
      ./.yath.rc
    ]);
  };

  strictDeps = true;

  nativeBuildInputs = [
    makeWrapper
    autoreconfHook
    nukeReferences
    pkg-config
    mdbook
    nix
    perlDeps
    perl
    unzip
  ];

  buildInputs = [
    libpqxx
    openssl
    libxslt
    nix
    perlDeps
    perl
    boost
    nlohmann_json
    prometheus-cpp
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
    postgresql_13
    pixz
  ];

  checkInputs = [
    cacert
    glibcLocales
    libressl.nc
    python3
  ];

  hydraPath = lib.makeBinPath (
    [
      subversion
      openssh
      nix
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
            --set NIX_RELEASE ${nix.name or "unknown"}
    done
  '';

  dontStrip = true;

  meta.description = "Build of Hydra on ${stdenv.system}";
  passthru = { inherit perlDeps nix; };
})

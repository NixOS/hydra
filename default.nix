{ pkgs ? (import <nixpkgs> {})
, version ? builtins.readFile ./version + ".HEAD"
, src ? ./.
}:

let
  # Build a version of nix that works with current hydra master
  # (Currently, revision 1a714952732c56b4735f65dea49d406aacc7c595 works)
  nixSrc = pkgs.fetchgit {
    url = "https://github.com/NixOS/nix";
    rev = "1a714952732c56b4735f65dea49d406aacc7c595";
    sha256 = "05nwfzg33v94hrrqr27vyd3lsg5ix0n9m0yxj1m7wa165ycf9qq6";
  };
  nixRelease = import "${nixSrc}/release.nix" {};
  nix = pkgs.lib.overrideDerivation nixRelease.build.${builtins.currentSystem} (_: {
    # The checks for this revision are broken, they try to create a /nix/var
    # directory which results in a permission denied error.
    doInstallCheck = false;

    # Nix's release.nix sets src to null if in nix shell. This means that
    # if you try to open a nix-shell on this default.nix, nix will fail to build.
    # We can fix this by overwriting the src.
    src = pkgs.lib.overrideDerivation nixRelease.tarball (_: { src = nixSrc; });
  });

  # Hydra currently requires a fork of aws-sdk-cpp with a few custom patches.
  aws-sdk-cpp = pkgs.lib.overrideDerivation (pkgs.aws-sdk-cpp.override {
    apis = ["s3"];
    customMemoryManagement = false;
  }) (attrs: {
    src = pkgs.fetchFromGitHub {
      owner = "edolstra";
      repo = "aws-sdk-cpp";
      rev = "local";
      sha256 = "1vhgsxkhpai9a7dk38q4r239l6dsz2jvl8hii24c194lsga3g84h";
    };
  });

  # Build a perl environment with all packages that hydra needs
  perlDeps = with pkgs; buildEnv {
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
        nix git boehmgc
      ];
  };


in pkgs.releaseTools.nixBuild {
  name = "hydra-${version}";
  inherit src;
  buildInputs = with pkgs; [
    makeWrapper autoconf automake libtool unzip nukeReferences pkgconfig sqlite libpqxx
    gitAndTools.topGit mercurial darcs subversion bazaar openssl bzip2 libxslt
    guile perlDeps perl nix postgresql92 aws-sdk-cpp
  ];
  configureFlags = [ "--with-docbook-xsl=${pkgs.docbook_xsl}/xml/xsl/docbook" ];

  hydraPath = with pkgs; lib.makeBinPath ([
    libxslt sqlite subversion openssh nix coreutils findutils
    gzip bzip2 lzma gnutar unzip git gitAndTools.topGit mercurial darcs gnused bazaar
  ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [ rpm dpkg cdrkit ]);

  preHook = ''
    PATH=$(pwd)/src/script:$(pwd)/src/hydra-eval-jobs:$(pwd)/src/hydra-queue-runner:$PATH
    PERL5LIB=$(pwd)/src/lib:$PERL5LIB;
  '';

  postUnpack = pkgs.lib.optionalString (!pkgs.lib.inNixShell) ''
    (cd $sourceRoot && (git ls-files -o --directory | xargs -r rm -rfv)) || true
  '';


  preConfigure = "autoreconf -vfi";

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
  enableParellelBuilding = true;

  passthru.perlDeps = perlDeps;
  meta.description = "Build of Hydra from Git";

  # Setup environment for running hydra from the nix-shell
  shellHook = ''
    mkdir -p data
    export HYDRA_DATA=$PWD/data
    export HYDRA_HOME=$PWD/src
  '';
}

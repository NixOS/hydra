{
  stdenv,
  lib,
  version,

  hydra,
  hydra-queue-runner,
  hydra-builder,
  hydra-drv-daemon,

  meson,
  ninja,
  socat,

  perl,
  nixComponents,

  bzip2,
  top-git,
  mercurial,
  darcs,
  subversion,
  breezy,
  openldap,
  postgresql_17,
  pixz,
  nix-eval-jobs,
  foreman,
  curl,

  cacert,
  glibcLocales,
  libressl,
  python3,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "hydra-tests";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../subprojects/hydra-tests
      ../../version.txt
    ];
  };

  sourceRoot = "${finalAttrs.src.name}/subprojects/hydra-tests";

  postPatch = ''
    patchShebangs .
  '';

  dontBuild = true;

  strictDeps = true;

  nativeBuildInputs = [
    meson
    ninja
    hydra
    hydra-queue-runner
    hydra-builder
    hydra-drv-daemon
    hydra.perlDeps
    perl
    nixComponents.nix-cli
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
    socat
    curl
  ];

  buildInputs = [
    cacert
    glibcLocales
    libressl.nc
    python3
    nixComponents.nix-cli
    hydra.perlDeps
    perl
  ];

  OPENLDAP_ROOT = openldap;

  mesonBuildType = "release";
  mesonFlags = [
    "-Dhydra_home=${hydra}/libexec/hydra"
  ];

  doCheck = true;

  mesonCheckFlags = [ "--interactive" ];

  preCheck = ''
    export LOGNAME=''${LOGNAME:-foo}
    export HOME=$(mktemp -d)
  '';

  installPhase = ''
    touch $out
  '';

  meta.description = "Tests for Hydra on ${stdenv.system}";
})

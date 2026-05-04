{
  lib,
  stdenv,
  pkg-config,
  meson,
  ninja,
  perl,
  perlPackages,
  nix-store,
  curl,
  bzip2,
  libsodium,
}:

perl.pkgs.toPerlModule (
  stdenv.mkDerivation (finalAttrs: {
    pname = "nix-perl";
    inherit (nix-store) version;

    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions (
        [
          ./MANIFEST
          ./lib
          ./meson.build
          ./meson.options
        ]
        ++ lib.optionals finalAttrs.finalPackage.doCheck [
          ./.yath.rc.in
          ./t
        ]
      );
    };

    nativeBuildInputs = [
      meson
      ninja
      pkg-config
      perl
      curl
    ];

    buildInputs = [
      nix-store
      bzip2
      libsodium
      perlPackages.DBI
      perlPackages.DBDSQLite
    ];

    # `perlPackages.Test2Harness` is marked broken for Darwin
    doCheck = !stdenv.isDarwin;

    nativeCheckInputs = [
      perlPackages.Test2Harness
    ];

    preConfigure = ''
      echo ${finalAttrs.version} > .version
    '';

    mesonBuildType = "release";

    mesonFlags = [
      (lib.mesonEnable "tests" finalAttrs.finalPackage.doCheck)
    ];

    mesonCheckFlags = [
      "--print-errorlogs"
    ];

    strictDeps = false;

    meta = {
      platforms = lib.platforms.unix;
    };
  })
)

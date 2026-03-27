{
  stdenv,
  lib,
  version,
  meson,
  ninja,
  mdbook,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "hydra-manual";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../subprojects/hydra-manual
      ../../version.txt
    ];
  };

  sourceRoot = "${finalAttrs.src.name}/subprojects/hydra-manual";

  nativeBuildInputs = [
    meson
    ninja
    mdbook
  ];

  postInstall = ''
    mkdir -p $out/nix-support
    echo "doc manual $out/share/doc/hydra" >> $out/nix-support/hydra-build-products
  '';

  meta.description = "Hydra manual";
})

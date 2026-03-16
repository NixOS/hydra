{ stdenv
, lib
, version
, perlPackages
, perl
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "hydra-linters";
  inherit version;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../subprojects/hydra
      ../../subprojects/hydra-linters
      ../../subprojects/hydra-tests
      ../../.perlcriticrc
      ../../version.txt
    ];
  };

  sourceRoot = "${finalAttrs.src.name}/subprojects/hydra-linters";

  nativeBuildInputs = [
    perl
    perlPackages.PerlCriticCommunity
  ];

  doCheck = true;

  installPhase = ''
    touch $out
  '';

  meta.description = "Linters for Hydra";
})

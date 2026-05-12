{
  lib,
  runCommand,
  diffutils,
  python3,
  cargo,
  src,
}:
let
  script = ../scripts/dependency-diagram.py;
  doc = ../subprojects/hydra-manual/src/architecture.md;
  generated =
    runCommand "generate-dependency-diagram"
      {
        nativeBuildInputs = [
          python3
          cargo
        ];
        inherit src script doc;
      }
      ''
        python3 "$script" \
          --doc "$doc" \
          --manifest-path $src/Cargo.toml \
          > "$out"
      '';
in
runCommand "check-dependency-diagram"
  {
    nativeBuildInputs = [ diffutils ];
  }
  ''
    if ! diff \
      --unified \
      --color=always \
      ${doc} \
      ${generated}; then
      echo "Dependency diagram is out of date. Update with:"
      echo "  cp ${generated} subprojects/hydra-manual/src/architecture.md"
      exit 1
    fi
    touch $out
  ''

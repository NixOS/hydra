let
  builder = builtins.toFile "builder.sh" ''
    echo -n ${builtins.readFile ./default.nix} > $out
  '';
in {
  job = derivation {
    name = "job";
    system = builtins.currentSystem;
    builder = "/bin/sh";
    args = [ builder ];
  };
}

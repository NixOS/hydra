let
  thisFile = builtins.toFile "default.nix" (builtins.readFile ./default.nix);
  builder = builtins.toFile "builder.sh" ''
    echo ${thisFile} > $out
  '';
in {
  job = derivation {
    name = "job";
    system = builtins.currentSystem;
    builder = "/bin/sh";
    args = [ builder ];
  };
}

{
  job = derivation {
    name = "job";
    system = builtins.currentSystem;
    builder = "/bin/sh";
    args = [ (builtins.toFile "builder.sh" ''
      touch $out
    '') ];
  };
  job2 = builtins.abort "This job should fail evaluation";
}

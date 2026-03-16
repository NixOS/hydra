# This file gets copied around, and intentionally does not refer to
# anything but itself as "default.nix".

let
  simpleDerivation = name: builderText: derivation {
    inherit name;
    system = builtins.currentSystem;
    builder = "/bin/sh";
    args = [
      (builtins.toFile "builder.sh" builderText)
    ];
  };
in
{
  stable-job-queued = simpleDerivation "stable-job-queued" ''
    echo "here is a stable job that passes every time" > $out
  '';

  stable-job-passing = simpleDerivation "stable-job-passing" ''
    echo "here is a stable job that passes every time" > $out
  '';

  stable-job-failing = simpleDerivation "stable-job-failing" ''
    echo "this job is a stable job that fails every time" > $out
  '';

  variable-job = simpleDerivation "variable-job" ''
    echo ${builtins.toFile "default.nix" (builtins.readFile ./default.nix)} > $out
  '';
}

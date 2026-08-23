with import ./config.nix;
let
  # Built during evaluation: interpolating it into a string forces nix
  # to realise it, and the `import` below then reads the result back
  # into the evaluator. Until that build finishes there is no way to
  # know what this jobset's jobs even are, which is what makes this a
  # build the evaluation needs rather than an ordinary dependency.
  job_list = mkDerivation {
    name = "generated-job-list";
    builder = ./job-list-builder.sh;
  };

  names = import "${job_list}/names.nix";
in
builtins.listToAttrs (
  map (name: {
    inherit name;
    value = mkDerivation {
      name = "generated-${name}";
      builder = ./empty-dir-builder.sh;
    };
  }) names
)

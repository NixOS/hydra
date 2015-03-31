let
  channel = derivation {
    name = "channel";
    system = builtins.currentSystem;
    builder = "/run/current-system/sw/bin/sh";
    args = [
      (builtins.toFile "builder.sh" ''
        #OVERRIDE# will be substituted in channels.pl
        /run/current-system/sw/bin/mkdir -p "$out"
        echo '"magic"' > "$out/default.nix"
      '')
    ];
  };

in {
  inherit channel;
  nested.channel = channel;
  another.name = channel;
  unrelatedJob = builtins.toFile "unrelated" "unrelated";
  another.unrelatedJob = builtins.toFile "unrelated" "unrelated";
  failedJob = derivation {
    name = "fail";
    system = builtins.currentSystem;
    builder = "/run/current-system/sw/bin/false";
  };
}

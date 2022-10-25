with import ./config.nix;
rec {
  foo-bar-baz = mkDerivation {
    name = "foo-bar-baz";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          touch $out
        ''
      )
    ];
  };

  runCommandHook.example = mkDerivation {
    name = "my-build-product";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          touch $out
          chmod +x $out
          # ... dunno ...
        ''
      )
    ];
  };

  runCommandHook.symlink = mkDerivation {
    name = "symlink-out";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          ln -s $1 $out
        ''
      )

      runCommandHook.example
    ];
  };

  runCommandHook.no-out = mkDerivation {
    name = "no-out";
    builder = "/bin/sh";
    outputs = [ "bin" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh
          mkdir $bin
        ''
      )
    ];
  };

  runCommandHook.out-is-directory = mkDerivation {
    name = "out-is-directory";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          mkdir $out
        ''
      )
    ];
  };

  runCommandHook.out-is-not-executable-file = mkDerivation {
    name = "out-is-directory";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          touch $out
        ''
      )
    ];
  };

  runCommandHook.symlink-non-executable = mkDerivation {
    name = "symlink-out";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          ln -s $1 $out
        ''
      )

      runCommandHook.out-is-not-executable-file
    ];
  };

  runCommandHook.symlink-directory = mkDerivation {
    name = "symlink-directory";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          ln -s $1 $out
        ''
      )

      runCommandHook.out-is-directory
    ];
  };

  runCommandHook.failed = mkDerivation {
    name = "failed";
    builder = "/bin/sh";
    outputs = [ "out" ];
    args = [
      (
        builtins.toFile "builder.sh" ''
          #! /bin/sh

          touch $out
          chmod +x $out

          exit 1
        ''
      )
    ];
  };

}

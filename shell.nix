{ nix ? null } @ args:

(import ./release.nix (args // {
  shell = true;
})).build.${builtins.currentSystem}

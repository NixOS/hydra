{ nix ? null, ... }@args:


let
  pkgs = import <nixpkgs> {};

  workingNix = let
    src = pkgs.lib.overrideDerivation (pkgs.fetchFromGitHub {
      owner = "NixOS";
      repo = "nix";
      rev = "1a714952732c56b4735f65dea49d406aacc7c595";
      sha256 = "1fkmz7gv73qm50xz1hm1wkhm0yij0p7h4wx0760lvm9gkf4x4bn8";
    }) (drv: {
      postFetch = (drv.postFetch or "") + ''
        # Don't hardcode XSL namespace URL:
        # https://github.com/NixOS/nix/pull/959
        sed -i -e '/^docbookxsl/s,xsl-ns/.*$,xsl-ns/current,' \
          "$out/doc/manual/local.mk"

        # Nix's release.nix sets src to null if in nix shell. This means that if
        # you try to open a nix-shell on this default.nix, Nix will fail to
        # build.
        # Let's patch it until https://github.com/NixOS/nix/pull/960 got merged.
        sed -i -e 's/lib\.inNixShell/false/g' "$out/release.nix"
      '';
    });
    release = import "${src}/release.nix" {};
  in pkgs.lib.overrideDerivation release.build.${builtins.currentSystem} (_: {
    # The checks for this revision are broken, they try to create a /nix/var
    # directory which results in a permission denied error.
    doInstallCheck = false;
  });

in (import ./release.nix (args // {
  nix = if nix == null then workingNix else nix;
  shell = pkgs.lib.inNixShell;
})).build.${builtins.currentSystem}

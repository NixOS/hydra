{
  outputs = { self, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: builtins.listToAttrs (map (system: { name = system; value = f system; }) systems);
    in {
      checks = forAllSystems (system:
        import ./basic.nix { inherit system; }
      );
    };
}

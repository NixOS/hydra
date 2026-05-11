{
  forEachSystem,
  nixpkgs,
  nixosModules,
}:

let
  common = import ./common.nix { inherit nixosModules; };
in

{

  install = forEachSystem (system: import ./install.nix { inherit system nixpkgs common; });

  notifications = forEachSystem (
    system: import ./notifications.nix { inherit system nixpkgs common; }
  );

  gitea = forEachSystem (system: import ./gitea.nix { inherit system nixpkgs common; });

  validate-openapi = forEachSystem (
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.runCommand "validate-openapi" { buildInputs = [ pkgs.openapi-generator-cli ]; } ''
      openapi-generator-cli validate -i ${../hydra-api.yaml}
      touch $out
    ''
  );

}

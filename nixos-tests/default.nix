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

  s3-nar-listing = forEachSystem (
    system: import ./s3-nar-listing.nix { inherit system nixpkgs common; }
  );

  s3-nar-listing-presigned = forEachSystem (
    system:
    import ./s3-nar-listing.nix {
      inherit system nixpkgs common;
      presigned = true;
    }
  );

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

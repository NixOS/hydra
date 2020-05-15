{
  description = "A Nix-based continuous build system";

  inputs.nixpkgs.url = "nixpkgs/nixos-20.03";

  # self   : this flake
  # nixpkgs: inputs.nixpkgs
  # nix    : from the flake registry
  outputs = { self, nixpkgs, nix }:
    let

      version = "${builtins.readFile ./version}.${builtins.substring 0 8 self.lastModifiedDate}.${self.shortRev or "DIRTY"}";

      # pkgs based on `inputs.nixpkgs` including
      # - `inputs.nix` via overlay
      # - `hydra` via overalay
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ self.hydraOverlay nix.overlay ];
      };


    in
      rec {

        packages.x86_64-linux.hydra = pkgs.hydra;

        defaultPackage.x86_64-linux = pkgs.hydra;

        # A Nixpkgs overlay that provides a 'hydra' package.
        hydraOverlay = final: prev: {
          hydra = final.callPackage ./nix/hydra.nix {
            hydraSrc = self.outPath;
            system = "x86_64-linux";
            inherit version;
          };
        };

        hydraJobs = pkgs.callPackage ./nix/hydra-jobs.nix {
          inherit packages nixpkgs version;
          inherit (nixosModules) hydraTest hydraProxy;
          inherit (self) rev;
        };

        checks.x86_64-linux = {
          build = hydraJobs.build.x86_64-linux;
          install = hydraJobs.tests.install.x86_64-linux;
        };


        nixosModules = {

          # The default hydra module
          hydra = {
            imports = [ ./hydra-module.nix ];
            nixpkgs.overlays = [ hydraOverlay nix.overlay ];
          };

          # Debug version of the hydra module
          hydraTest = {
            imports = [ self.nixosModules.hydra ];

            services.hydra-dev.enable = true;
            services.hydra-dev.hydraURL = "http://hydra.example.org";
            services.hydra-dev.notificationSender = "admin@hydra.example.org";

            systemd.services.hydra-send-stats.enable = false;

            services.postgresql.enable = true;
            services.postgresql.package = pkgs.postgresql95;

            # The following is to work around the following error from hydra-server:
            #   [error] Caught exception in engine "Cannot determine local time zone"
            time.timeZone = "UTC";

            nix.extraOptions = ''
              allowed-uris = https://github.com/
            '';
          };

          # Apache proxy for Hydra
          hydraProxy = {
            services.httpd = {
              enable = true;
              adminAddr = "hydra-admin@example.org";
              extraConfig = ''
                <Proxy *>
                  Order deny,allow
                  Allow from all
                </Proxy>

                ProxyRequests     Off
                ProxyPreserveHost On
                ProxyPass         /apache-errors !
                ErrorDocument 503 /apache-errors/503.html
                ProxyPass         /       http://127.0.0.1:3000/ retry=5 disablereuse=on
                ProxyPassReverse  /       http://127.0.0.1:3000/
              '';
            };
          };

        };
      };
}

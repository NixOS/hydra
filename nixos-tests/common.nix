{
  nixosModules,
}:

let
  # Shared nix settings for all test VMs
  nixSettings = {
    settings.substituters = [ ];
  };
in

{
  serverConfig =
    { pkgs, ... }:
    {
      imports = [
        nixosModules.web-app
        nixosModules.queue-runner
      ];

      services.hydra-dev.enable = true;
      services.hydra-dev.hydraURL = "http://hydra.example.org";
      services.hydra-dev.notificationSender = "admin@hydra.example.org";

      services.hydra-queue-runner-dev.enable = true;
      services.hydra-queue-runner-dev.grpc.address = "[::]";

      systemd.services.hydra-send-stats.enable = false;

      services.postgresql.enable = true;

      time.timeZone = "UTC";

      nix = nixSettings // {
        extraOptions = ''
          allowed-uris = https://github.com/
        '';
      };

      networking.firewall.allowedTCPPorts = [ 50051 ];

      virtualisation.memorySize = 2048;
      virtualisation.writableStore = true;

      environment.systemPackages = [
        pkgs.perlPackages.LWP
        pkgs.perlPackages.JSON
      ];
    };

  builderConfig =
    { ... }:
    {
      imports = [
        nixosModules.builder
      ];

      services.hydra-queue-builder-dev.enable = true;
      services.hydra-queue-builder-dev.queueRunnerAddr = "http://server:50051";

      virtualisation.memorySize = 2048;
      virtualisation.writableStore = true;

      nix = nixSettings;
    };
}

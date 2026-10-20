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
  setupJobset =
    pkgs:
    { project, jobset }:
    pkgs.writeShellScript "setup-jobset.sh" ''
      set -eux
      mkdir -p /run/jobset
      cp ${jobset} /run/jobset/default.nix
      chmod 644 /run/jobset/default.nix
      chown -R hydra /run/jobset

      su -l hydra -c "hydra-create-user root --email-address 'alice@example.org' \
        --password foobar --role admin"

      URL=http://localhost:3000
      mycurl() {
        curl --fail --silent --referer $URL -H "Accept: application/json" \
          -H "Content-Type: application/json" "$@"
      }

      mycurl -X POST -d '{"username":"root","password":"foobar"}' \
        $URL/login -c hydra-cookie.txt

      mycurl -X PUT $URL/project/${project} -b hydra-cookie.txt -d '{
        "displayname": "${project}",
        "enabled": "1",
        "visible": "1"
      }'

      mycurl -X PUT $URL/jobset/${project}/default -b hydra-cookie.txt -d '{
        "description": "${project}",
        "checkinterval": "5",
        "enabled": "1",
        "visible": "1",
        "keepnr": "1",
        "type": 0,
        "nixexprinput": "src",
        "nixexprpath": "default.nix",
        "inputs": {
          "src": { "type": "path", "value": "/run/jobset" }
        }
      }'
    '';

  serverConfig =
    { pkgs, ... }:
    {
      imports = [
        nixosModules.web-app
        nixosModules.evaluator
        nixosModules.queue-runner
        nixosModules.ad-hoc
      ];

      services.hydra-dev.enable = true;
      services.hydra-dev.hydraURL = "http://hydra.example.org";
      services.hydra-dev.notificationSender = "admin@hydra.example.org";

      services.hydra-queue-runner-dev.enable = true;
      services.hydra-queue-runner-dev.grpc.address = "[::]";

      services.hydra-ad-hoc-dev.enable = true;

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

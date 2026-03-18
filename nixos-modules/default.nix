{ flakePackages }:

rec {
  web-app = { pkgs, lib, ... }: {
    _file = ./default.nix;
    imports = [ ./web-app.nix ];
    services.hydra-dev.package =
      lib.mkDefault flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra;
  };

  queue-runner = { pkgs, lib, ... }: {
    _file = ./default.nix;
    imports = [ ./queue-runner-module.nix ];
    services.hydra-queue-runner-dev.package =
      lib.mkDefault flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra-queue-runner;
  };

  linux-builder = { pkgs, lib, ... }: {
    _file = ./default.nix;
    imports = [ ./linux-builder-module.nix ];
    services.hydra-queue-builder-dev.package =
      lib.mkDefault flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra-queue-runner;
  };

  darwin-builder = { pkgs, lib, ... }: {
    _file = ./default.nix;
    imports = [ ./darwin-builder-module.nix ];
    services.hydra-queue-builder-dev.package =
      lib.mkDefault flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra-queue-runner;
  };

  hydra = { ... }: {
    _file = ./default.nix;
    imports = [
      web-app
      queue-runner
      linux-builder
    ];
  };

  hydraTest = { pkgs, ... }: {
    services.hydra-dev.enable = true;
    services.hydra-dev.hydraURL = "http://hydra.example.org";
    services.hydra-dev.notificationSender = "admin@hydra.example.org";

    systemd.services.hydra-send-stats.enable = false;

    services.postgresql.enable = true;

    # The following is to work around the following error from hydra-server:
    #   [error] Caught exception in engine "Cannot determine local time zone"
    time.timeZone = "UTC";

    nix.extraOptions = ''
      allowed-uris = https://github.com/
    '';
  };

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
}

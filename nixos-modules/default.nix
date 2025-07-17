{ self }:

{
  hydra = { pkgs, lib,... }: {
    _file = ./default.nix;
    imports = [ ./hydra.nix ];
    services.hydra-dev.package = lib.mkDefault self.packages.${pkgs.hostPlatform.system}.hydra;
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

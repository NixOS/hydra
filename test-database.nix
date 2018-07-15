{ pkgs, ... }:
{
  services.postgresql = {
    enable = true;
    ensureDatabases = [ "hydra" ];
    ensureUsers = [
      { name = "hydra";
        ensurePermissions."DATABASE hydra" = "ALL PRIVILEGES";
      }
    ];
    authentication = ''
      host all all all trust
    '';
    enableTCPIP = true;
  };

  networking.firewall.allowedTCPPorts = [ 5432 ];
}

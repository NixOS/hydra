{ flakePackages }:

rec {
  web-app =
    { pkgs, lib, ... }:
    {
      _file = ./default.nix;
      imports = [ ./web-app.nix ];
      services.hydra-dev.package = lib.mkDefault flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra;
      services.hydra-dev.evaluatorExecutable = lib.mkDefault "${
        flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra-evaluator
      }/bin/hydra-evaluator";
    };

  postgresql = ./postgresql.nix;

  queue-runner =
    { pkgs, lib, ... }:
    {
      _file = ./default.nix;
      imports = [ ./queue-runner-module.nix ];
      services.hydra-queue-runner-dev.package =
        lib.mkDefault
          flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra-queue-runner;
    };

  builder =
    { pkgs, lib, ... }:
    {
      _file = ./default.nix;
      imports = [ ./builder-module.nix ];
      services.hydra-queue-builder-dev.package =
        lib.mkDefault
          flakePackages.${pkgs.stdenv.hostPlatform.system}.hydra-builder;
    };

  hydra =
    { ... }:
    {
      _file = ./default.nix;
      imports = [
        web-app
        queue-runner
        builder
      ];
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

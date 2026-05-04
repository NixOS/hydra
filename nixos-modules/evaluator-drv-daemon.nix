{
  config,
  lib,
  ...
}:
let
  cfg = config.services.hydra-evaluator-dev;
  daemon = config.services.hydra-drv-daemon-dev;
in
{
  options.services.hydra-evaluator-dev = {
    routeIfdsThroughDaemon = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Route hydra-evaluator's IFD store ops through hydra-drv-daemon
        by setting `NIX_REMOTE` on the evaluator service. The daemon
        creates an ad-hoc Build per IFD so the queue-runner / builder
        pair handles the build instead of the evaluator host.

        Has no effect unless `services.hydra-drv-daemon-dev.enable` is
        also set.

        Note: routing only takes effect if `allowImportFromDerivation`
        is true; otherwise nix-eval-jobs rejects every IFD before the
        daemon can see it.
      '';
    };

    allowImportFromDerivation = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add `allow_import_from_derivation = true` to hydra.conf.
        Untrusted Nix expressions can run builders during eval, which
        is why this stays opt-in.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.routeIfdsThroughDaemon {
      assertions = [
        {
          assertion = daemon.enable;
          message = ''
            services.hydra-evaluator-dev.routeIfdsThroughDaemon requires
            services.hydra-drv-daemon-dev.enable.
          '';
        }
      ];

      systemd.services.hydra-evaluator = {
        after = [ "hydra-drv-daemon.service" ];
        requires = [ "hydra-drv-daemon.service" ];
        environment.NIX_REMOTE = "unix://${daemon.socketPath}";
      };

      warnings = lib.optional (!cfg.allowImportFromDerivation) ''
        services.hydra-evaluator-dev.routeIfdsThroughDaemon is enabled but
        services.hydra-evaluator-dev.allowImportFromDerivation is not.
        IFDs will be rejected by nix-eval-jobs before reaching the
        daemon, so the routing has no effect.
      '';
    })
    (lib.mkIf cfg.allowImportFromDerivation {
      services.hydra-dev.extraConfig = ''
        allow_import_from_derivation = true
      '';
    })
  ];
}

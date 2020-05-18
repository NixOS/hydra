{
  hydra,
  hydraProxy,
  hydraTest,
  nixpkgs,
  perlPackages,
  rev,
  runCommand,
  system,
  version
}:

let

  nixosConfigurations.container = nixpkgs.lib.nixosSystem {
    inherit system;
    modules =
      [
        hydraTest
        hydraProxy
        {
          system.configurationRevision = rev;

          boot.isContainer = true;
          networking.useDHCP = false;
          networking.firewall.allowedTCPPorts = [ 80 ];
          networking.hostName = "hydra";

          services.hydra-dev.useSubstitutes = true;
        }
      ];
  };

  hydraServer =
    { config, pkgs, ... }:
      {
        imports = [ hydraTest ];

        virtualisation.memorySize = 1024;
        virtualisation.writableStore = true;

        environment.systemPackages = [ perlPackages.LWP perlPackages.JSON ];

        nix = {
          # Without this nix tries to fetch packages from the default
          # cache.nixos.org which is not reachable from this sandboxed NixOS test.
          binaryCaches = [];
        };
      };

in
{

  build.x86_64-linux = hydra;

  manual =
    runCommand "hydra-manual-${version}" {}
      ''
        mkdir -p $out/share
        cp -prvd ${hydra}/share/doc $out/share/

            mkdir $out/nix-support
            echo "doc manual $out/share/doc/hydra" >> $out/nix-support/hydra-build-products
      '';

  tests.install.x86_64-linux =
    with import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; };
    simpleTest {
      machine = hydraServer;
      testScript =
        ''
          machine.wait_for_job("hydra-init")
          machine.wait_for_job("hydra-server")
          machine.wait_for_job("hydra-evaluator")
          machine.wait_for_job("hydra-queue-runner")
          machine.wait_for_open_port("3000")
          machine.succeed("curl --fail http://localhost:3000/")
        '';
    };

  tests.api.x86_64-linux =
    with import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; };
    simpleTest {
      machine = hydraServer;
      testScript =
        let
          dbi = "dbi:Pg:dbname=hydra;user=root;";
        in
          ''
              machine.wait_for_job("hydra-init")

            # Create an admin account and some other state.
              machine.succeed(
                """
                    su - hydra -c "hydra-create-user root --email-address 'alice@example.org' --password foobar --role admin"
                    mkdir /run/jobset /tmp/nix
                    chmod 755 /run/jobset /tmp/nix
                    cp ${./tests/api-test.nix} /run/jobset/default.nix
                    chmod 644 /run/jobset/default.nix
                    chown -R hydra /run/jobset /tmp/nix
              """
              )

              machine.succeed("systemctl stop hydra-evaluator hydra-queue-runner")
              machine.wait_for_job("hydra-server")
              machine.wait_for_open_port("3000")

            # Run the API tests.
              machine.succeed(
                "su - hydra -c 'perl -I ${hydra.perlDeps}/lib/perl5/site_perl ${./tests/api-test.pl}' >&2"
              )
          '';
    };

  tests.notifications.x86_64-linux =
    with import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; };
    simpleTest {
      machine = { ... }: {
        imports = [ hydraServer ];
        services.hydra-dev.extraConfig = ''
          <influxdb>
          url = http://127.0.0.1:8086
          db = hydra
          </influxdb>
        '';
        services.influxdb.enable = true;
      };
      testScript = ''
              machine.wait_for_job("hydra-init")

        # Create an admin account and some other state.
              machine.succeed(
              """
                su - hydra -c "hydra-create-user root --email-address 'alice@example.org' --password foobar --role admin"
                mkdir /run/jobset
                chmod 755 /run/jobset
                cp ${./tests/api-test.nix} /run/jobset/default.nix
                chmod 644 /run/jobset/default.nix
                chown -R hydra /run/jobset
              """
              )

        # Wait until InfluxDB can receive web requests
              machine.wait_for_job("influxdb")
              machine.wait_for_open_port("8086")

        # Create an InfluxDB database where hydra will write to
              machine.succeed(
              "curl -XPOST 'http://127.0.0.1:8086/query' "
              + "--data-urlencode 'q=CREATE DATABASE hydra'"
              )

        # Wait until hydra-server can receive HTTP requests
              machine.wait_for_job("hydra-server")
              machine.wait_for_open_port("3000")

        # Setup the project and jobset
              machine.succeed(
              "su - hydra -c 'perl -I ${hydra.perlDeps}/lib/perl5/site_perl ${./tests/setup-notifications-jobset.pl}' >&2"
              )

        # Wait until hydra has build the job and
        # the InfluxDBNotification plugin uploaded its notification to InfluxDB
              machine.wait_until_succeeds(
              "curl -s -H 'Accept: application/csv' "
              + "-G 'http://127.0.0.1:8086/query?db=hydra' "
              + "--data-urlencode 'q=SELECT * FROM hydra_build_status' | grep success"
              )
      '';
    };

  container = nixosConfigurations.container.config.system.build.toplevel;
}

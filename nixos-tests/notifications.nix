{
  system,
  nixpkgs,
  common,
}:

(import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).simpleTest {
  name = "hydra-notifications";
  nodes.server = {
    imports = [ common.serverConfig ];
    services.hydra-dev.extraConfig = ''
      <influxdb>
        url = http://127.0.0.1:8086
        db = hydra
      </influxdb>
    '';
    services.influxdb.enable = true;
  };
  nodes.builder = common.builderConfig;
  testScript =
    { nodes, ... }:
    ''
      server.wait_for_unit("hydra-init.service")
      server.wait_for_unit("hydra-queue-runner-dev.service")
      builder.wait_for_unit("hydra-queue-builder-dev.service")

      # Create an admin account and some other state.
      server.succeed(
          """
              su - hydra -c "hydra-create-user root --email-address 'alice@example.org' --password foobar --role admin"
              mkdir /run/jobset
              chmod 755 /run/jobset
              cp ${../subprojects/hydra-tests/jobs/api-test.nix} /run/jobset/default.nix
              chmod 644 /run/jobset/default.nix
              chown -R hydra /run/jobset
      """
      )

      # Wait until InfluxDB can receive web requests
      server.wait_for_unit("influxdb.service")
      server.wait_for_open_port(8086)

      # Create an InfluxDB database where hydra will write to
      server.succeed(
          "curl -XPOST 'http://127.0.0.1:8086/query' "
          + "--data-urlencode 'q=CREATE DATABASE hydra'"
      )

      # Wait until hydra-server can receive HTTP requests
      server.wait_for_unit("hydra-server.service")
      server.wait_for_open_port(3000)

      # Setup the project and jobset
      server.succeed(
          "su - hydra -c 'perl -I ${nodes.server.services.hydra-dev.package.perlDeps}/lib/perl5/site_perl ${../subprojects/hydra-tests/setup-notifications-jobset.pl}' >&2"
      )

      # Wait until hydra has build the job and
      # the InfluxDBNotification plugin uploaded its notification to InfluxDB
      server.wait_until_succeeds(
          "curl -s -H 'Accept: application/csv' "
          + "-G 'http://127.0.0.1:8086/query?db=hydra' "
          + "--data-urlencode 'q=SELECT * FROM hydra_build_status' | grep success"
      )
    '';
}

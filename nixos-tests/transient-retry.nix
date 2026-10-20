# Regression test for https://github.com/NixOS/hydra/issues/2002: a step that
# fails with a transient failure (here: a fetchurl whose source is down) must
# be retried and eventually succeed once the source is back.
{
  system,
  nixpkgs,
  common,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};

  # builtin:fetchurl runs on the builder node, so the source is served there.
  jobset = pkgs.writeText "jobset.nix" ''
    {
      hello = derivation {
        name = "hello.txt";
        system = "builtin";
        builder = "builtin:fetchurl";
        url = "http://localhost:8000/hello.txt";
        unpack = false;
        executable = false;
        outputHashMode = "flat";
        outputHashAlgo = "sha256";
        outputHash = "sha256-WJG1tSLV3whtD/CxEPvZ0hu0/HFjrzTQgoai6Eb2vgM=";
      };
    }
  '';

  setupJobset = pkgs.writeShellScript "setup-jobset.sh" ''
    set -eux
    su -l hydra -c "hydra-create-user root --email-address 'alice@example.org' \
      --password foobar --role admin"

    URL=http://localhost:3000
    mycurl() {
      curl --fail --silent --referer $URL -H "Accept: application/json" \
        -H "Content-Type: application/json" "$@"
    }

    mycurl -X POST -d '{"username":"root","password":"foobar"}' \
      $URL/login -c hydra-cookie.txt

    mycurl -X PUT $URL/project/retry -b hydra-cookie.txt -d '{
      "displayname": "Retry",
      "enabled": "1",
      "visible": "1"
    }'

    mycurl -X PUT $URL/jobset/retry/default -b hydra-cookie.txt -d '{
      "description": "transient failure retry regression",
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
in

(import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).makeTest {
  name = "hydra-transient-retry";
  nodes.server = {
    imports = [ common.serverConfig ];
    # retries are only picked up by the periodic dispatch (default 120s)
    services.hydra-queue-runner-dev.settings = {
      retryInterval = 5;
      dispatchTriggerTimerInS = 10;
    };
  };
  nodes.builder = {
    imports = [ common.builderConfig ];
  };
  testScript = ''
    server.wait_for_unit("hydra-queue-runner-dev.service")
    builder.wait_for_unit("hydra-queue-builder-dev.service")
    server.wait_for_unit("hydra-server.service")
    server.wait_for_open_port(3000)

    server.succeed(
        "mkdir -p /run/jobset && "
        + "cp ${jobset} /run/jobset/default.nix && "
        + "chmod 644 /run/jobset/default.nix && chown -R hydra /run/jobset"
    )
    server.succeed("${setupJobset}")

    server.wait_until_succeeds(
        "journalctl -u hydra-queue-runner-dev | grep -q 'will retry'", timeout=300
    )

    builder.succeed("mkdir -p /srv && echo hello > /srv/hello.txt")
    builder.succeed("systemd-run --unit=src ${pkgs.python3.interpreter} -m http.server 8000 -d /srv")
    builder.wait_for_open_port(8000)

    server.wait_until_succeeds(
        "curl -sf 'http://localhost:3000/api/latestbuilds?nr=1&project=retry&jobset=default&job=hello' "
        + "| ${pkgs.jq}/bin/jq -e '.[0].buildstatus == 0'",
        timeout=300,
    )
  '';
}

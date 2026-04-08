{
  forEachSystem,
  nixpkgs,
  nixosModules,
}:

let
  # Shared nix settings for all test VMs
  nixSettings = {
    settings.substituters = [ ];
  };

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

in

{

  install = forEachSystem (
    system:
    (import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).simpleTest {
      name = "hydra-install";
      nodes.server = serverConfig;
      nodes.builder = builderConfig;
      testScript = ''
        server.wait_for_job("hydra-init")
        server.wait_for_job("hydra-server")
        server.wait_for_job("hydra-evaluator")
        server.wait_for_job("hydra-queue-runner-dev")
        builder.wait_for_job("hydra-queue-builder-dev")
        server.wait_for_open_port(3000)
        server.succeed("curl --fail http://localhost:3000/")
      '';
    }
  );

  notifications = forEachSystem (
    system:
    (import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).simpleTest {
      name = "hydra-notifications";
      nodes.server = {
        imports = [ serverConfig ];
        services.hydra-dev.extraConfig = ''
          <influxdb>
            url = http://127.0.0.1:8086
            db = hydra
          </influxdb>
        '';
        services.influxdb.enable = true;
      };
      nodes.builder = builderConfig;
      testScript =
        { nodes, ... }:
        ''
          server.wait_for_job("hydra-init")
          server.wait_for_job("hydra-queue-runner-dev")
          builder.wait_for_job("hydra-queue-builder-dev")

          # Create an admin account and some other state.
          server.succeed(
              """
                  su - hydra -c "hydra-create-user root --email-address 'alice@example.org' --password foobar --role admin"
                  mkdir /run/jobset
                  chmod 755 /run/jobset
                  cp ${./subprojects/hydra-tests/jobs/api-test.nix} /run/jobset/default.nix
                  chmod 644 /run/jobset/default.nix
                  chown -R hydra /run/jobset
          """
          )

          # Wait until InfluxDB can receive web requests
          server.wait_for_job("influxdb")
          server.wait_for_open_port(8086)

          # Create an InfluxDB database where hydra will write to
          server.succeed(
              "curl -XPOST 'http://127.0.0.1:8086/query' "
              + "--data-urlencode 'q=CREATE DATABASE hydra'"
          )

          # Wait until hydra-server can receive HTTP requests
          server.wait_for_job("hydra-server")
          server.wait_for_open_port(3000)

          # Setup the project and jobset
          server.succeed(
              "su - hydra -c 'perl -I ${nodes.server.services.hydra-dev.package.perlDeps}/lib/perl5/site_perl ${./subprojects/hydra-tests/setup-notifications-jobset.pl}' >&2"
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
  );

  gitea = forEachSystem (
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    (import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).makeTest {
      name = "hydra-gitea";
      nodes.server =
        { pkgs, ... }:
        {
          imports = [ serverConfig ];
          services.hydra-dev.extraConfig = ''
            <gitea_authorization>
            root=d7f16a3412e01a43a414535b16007c6931d3a9c7
            </gitea_authorization>
          '';
          nixpkgs.config.permittedInsecurePackages = [ "gitea-1.19.4" ];
          services.gitea = {
            enable = true;
            database.type = "postgres";
            settings = {
              service.DISABLE_REGISTRATION = true;
              server.HTTP_PORT = 3001;
            };
          };
          services.openssh.enable = true;
          environment.systemPackages = with pkgs; [
            gitea
            git
            jq
            gawk
          ];
          networking.firewall.allowedTCPPorts = [ 3000 ];
        };
      nodes.builder = builderConfig;
      skipLint = true;
      testScript =
        let
          scripts.mktoken = pkgs.writeText "token.sql" ''
            INSERT INTO access_token (id, uid, name, created_unix, updated_unix, token_hash, token_salt, token_last_eight, scope) VALUES (1, 1, 'hydra', 1617107360, 1617107360, 'a930f319ca362d7b49a4040ac0af74521c3a3c3303a86f327b01994430672d33b6ec53e4ea774253208686c712495e12a486', 'XRjWE9YW0g', '31d3a9c7', 'all');
          '';

          scripts.git-setup = pkgs.writeShellScript "setup.sh" ''
            set -x
            mkdir -p /tmp/repo $HOME/.ssh
            cat ${snakeoilKeypair.privkey} > $HOME/.ssh/privk
            chmod 0400 $HOME/.ssh/privk
            git -C /tmp/repo init
            cp ${smallDrv} /tmp/repo/jobset.nix
            git -C /tmp/repo add .
            git config --global user.email test@localhost
            git config --global user.name test
            git -C /tmp/repo commit -m 'Initial import'
            git -C /tmp/repo remote add origin gitea@server:root/repo
            GIT_SSH_COMMAND='ssh -i $HOME/.ssh/privk -o StrictHostKeyChecking=no' \
              git -C /tmp/repo push origin master
            git -C /tmp/repo log >&2
          '';

          scripts.hydra-setup = pkgs.writeShellScript "hydra.sh" ''
            set -x
            su -l hydra -c "hydra-create-user root --email-address \
              'alice@example.org' --password foobar --role admin"

            URL=http://localhost:3000
            USERNAME="root"
            PASSWORD="foobar"
            PROJECT_NAME="trivial"
            JOBSET_NAME="trivial"
            mycurl() {
              curl --referer $URL -H "Accept: application/json" \
                -H "Content-Type: application/json" $@
            }

            cat >data.json <<EOF
            { "username": "$USERNAME", "password": "$PASSWORD" }
            EOF
            mycurl -X POST -d '@data.json' $URL/login -c hydra-cookie.txt

            cat >data.json <<EOF
            {
              "displayname":"Trivial",
              "enabled":"1",
              "visible":"1"
            }
            EOF
            mycurl --silent -X PUT $URL/project/$PROJECT_NAME \
              -d @data.json -b hydra-cookie.txt

            cat >data.json <<EOF
            {
              "description": "Trivial",
              "checkinterval": "60",
              "enabled": "1",
              "visible": "1",
              "keepnr": "1",
              "enableemail": true,
              "emailoverride": "hydra@localhost",
              "type": 0,
              "nixexprinput": "git",
              "nixexprpath": "jobset.nix",
              "inputs": {
                "git": {"value": "http://localhost:3001/root/repo.git", "type": "git"},
                "gitea_repo_name": {"value": "repo", "type": "string"},
                "gitea_repo_owner": {"value": "root", "type": "string"},
                "gitea_status_repo": {"value": "git", "type": "string"},
                "gitea_http_url": {"value": "http://localhost:3001", "type": "string"}
              }
            }
            EOF

            mycurl --silent -X PUT $URL/jobset/$PROJECT_NAME/$JOBSET_NAME \
              -d @data.json -b hydra-cookie.txt
          '';

          api_token = "d7f16a3412e01a43a414535b16007c6931d3a9c7";

          snakeoilKeypair = {
            privkey = pkgs.writeText "privkey.snakeoil" ''
              -----BEGIN EC PRIVATE KEY-----
              MHcCAQEEIHQf/khLvYrQ8IOika5yqtWvI0oquHlpRLTZiJy5dRJmoAoGCCqGSM49
              AwEHoUQDQgAEKF0DYGbBwbj06tA3fd/+yP44cvmwmHBWXZCKbS+RQlAKvLXMWkpN
              r1lwMyJZoSGgBHoUahoYjTh9/sJL7XLJtA==
              -----END EC PRIVATE KEY-----
            '';

            pubkey = pkgs.lib.concatStrings [
              "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHA"
              "yNTYAAABBBChdA2BmwcG49OrQN33f/sj+OHL5sJhwVl2Qim0vkUJQCry1zFpKTa"
              "9ZcDMiWaEhoAR6FGoaGI04ff7CS+1yybQ= sakeoil"
            ];
          };

          smallDrv = pkgs.writeText "jobset.nix" ''
            { trivial = builtins.derivation {
                name = "trivial";
                system = "${system}";
                builder = "/bin/sh";
                allowSubstitutes = false;
                preferLocalBuild = true;
                args = ["-c" "echo success > $out; exit 0"];
              };
             }
          '';
        in
        ''
          import json

          server.start()
          builder.start()
          server.wait_for_unit("multi-user.target")
          server.wait_for_job("hydra-queue-runner-dev")
          builder.wait_for_job("hydra-queue-builder-dev")
          server.wait_for_open_port(3000)
          server.wait_for_open_port(3001)

          server.succeed(
              "su -l gitea -c 'GITEA_WORK_DIR=/var/lib/gitea gitea admin user create "
              + "--username root --password root --email test@localhost'"
          )
          server.succeed("su -l postgres -c 'psql gitea < ${scripts.mktoken}'")

          server.succeed(
              "curl --fail -X POST http://localhost:3001/api/v1/user/repos "
              + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
              + f"-H 'Authorization: token ${api_token}'"
              + ' -d \'{"auto_init":false, "description":"string", "license":"mit", "name":"repo", "private":false}\'''
          )

          server.succeed(
              "curl --fail -X POST http://localhost:3001/api/v1/user/keys "
              + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
              + f"-H 'Authorization: token ${api_token}'"
              + ' -d \'{"key":"${snakeoilKeypair.pubkey}","read_only":true,"title":"SSH"}\'''
          )

          server.succeed(
              "${scripts.git-setup}"
          )

          server.succeed(
              "${scripts.hydra-setup}"
          )

          server.wait_until_succeeds(
              'curl -Lf -s http://localhost:3000/build/1 -H "Accept: application/json" '
              + '|  jq .buildstatus | xargs test 0 -eq'
          )

          data = server.succeed(
              'curl -Lf -s "http://localhost:3001/api/v1/repos/root/repo/statuses/$(cd /tmp/repo && git show | head -n1 | awk "{print \\$2}")" '
              + "-H 'Accept: application/json' -H 'Content-Type: application/json' "
              + f"-H 'Authorization: token ${api_token}'"
          )

          response = json.loads(data)

          assert len(response) == 2, "Expected exactly two status updates for latest commit (queued, finished)!"
          items = {item['status'] for item in response}
          assert items == {"success", "pending"}, "Expected one success status and one pending status"

          server.shutdown()
        '';
    }
  );

  validate-openapi = forEachSystem (
    system:
    let
      pkgs = nixpkgs.legacyPackages.${system};
    in
    pkgs.runCommand "validate-openapi" { buildInputs = [ pkgs.openapi-generator-cli ]; } ''
      openapi-generator-cli validate -i ${./hydra-api.yaml}
      touch $out
    ''
  );

}

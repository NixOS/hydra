{ nixpkgs, module, package, lib, pkgs, simpleTest }:

let
  base = { pkgs, lib, config, ... }: {
    virtualisation.memorySize = 4096;
    imports = [ module ];
    environment.systemPackages = [ pkgs.jq ];
    nix = {
      distributedBuilds = true;
      buildMachines = [{
        hostName = "localhost";
        systems = [ "x86_64-linux" ];
      }];
      binaryCaches = [];
    };
    services.hydra-dev = {
      enable = true;
      hydraURL = "example.com";
      notificationSender = "webmaster@example.com";
    };
  };
in simpleTest {
  nodes = {
    original = { pkgs, lib, config, ... }: {
      imports = [ base ];
      services.hydra-dev.package = package.overrideAttrs (old: rec {
        inherit (old) name;
        src = pkgs.fetchFromGitHub {
          owner = "NixOS";
          repo = "hydra";
          rev = "9ae676072c4b4516503b8e661a1261e5a9b4dc95";
          sha256 = "sha256-kw6ogxYmSfB26lLpBF/hEP7uJbrjuWgw8L2OjrD5JiM=";
        };
      });
    };
    new = { pkgs, lib, config, ... }: {
      imports = [ base ];
      services.hydra-dev = { inherit package; };
    };
  };

  testScript = { nodes, ... }:
    let
      new = nodes.new.config.system.build.toplevel;

      username = "admin";
      password = "admin";
      project = "Test";
      jobset = "Test";

      credentials = pkgs.writeText "credentials.json" (builtins.toJSON {
        inherit username password;
      });

      proj_payload = pkgs.writeText "project.json" (builtins.toJSON {
        displayname = project;
        enabled = toString 1;
        visible = toString 1;
      });

      elWithTwoMaintainers = 2;

      testexpr = pkgs.writeTextDir "test.nix" ''
        {
          ${lib.flip lib.concatMapStrings [ "demo1" "demo2" "demo3" "demo4" "demo5" ] (name: ''
            ${name} = let
              builder = builtins.toFile "builder.sh" '''
                echo ${name} > $out
              ''';
            in builtins.derivation {
              name = "drv-${name}";
              system = "x86_64-linux";
              builder = "/bin/sh";
              args = [ builder ];
              allowSubstitutes = false;
              preferLocalBuild = true;
              meta.maintainers = [
                { github = "Ma27"; email = "ma27@localhost"; }
                ${lib.optionalString (name == "demo${toString elWithTwoMaintainers}") ''
                  { github = "foobar"; email = "foo@localhost"; }
                ''}
              ];
              meta.outPath = placeholder "out";
            };
          '')}
        }
      '';

      jobset_payload = pkgs.writeText "jobset.json" (builtins.toJSON {
        description = jobset;
        checkinterval = toString 60;
        enabled = toString 1;
        visible = toString 1;
        keepnr = toString 1;
        enableemail = true;
        emailoverride = "hydra@localhost";
        nixexprinput = "test";
        nixexprpath = "test.nix";
        inputs.test = {
          value = "${testexpr}";
          type = "path";
        };
      });

      setupJobset = pkgs.writeShellScript "setup.sh" ''
        set -euxo pipefail

        echo >&2 "Creating user from $(<${credentials})..."
        curl >&2 --fail -X POST -d '@${credentials}' \
          --referer http://localhost:3000 \
          -H "Accept: application/json" -H "Content-Type: application/json" \
          http://localhost:3000/login \
          -c /tmp/cookie.txt

        echo >&2 "\nCreating project from $(<${proj_payload})..."
        curl >&2 --fail -X PUT -d '@${proj_payload}' \
          --referer http://localhost:3000 \
          -H "Accept: application/json" -H "Content-Type: application/json" \
          http://localhost:3000/project/${project} \
          -b /tmp/cookie.txt

        echo >&2 "\nCreating jobset from $(<${jobset_payload})..."
        curl >&2 --fail -X PUT -d '@${jobset_payload}' \
          --referer http://localhost:3000 \
          -H "Accept: application/json" -H "Content-Type: application/json" \
          http://localhost:3000/jobset/${project}/${jobset} \
          -b /tmp/cookie.txt
      '';
    in ''
      original.start()

      # Setup
      original.wait_for_unit("multi-user.target")
      original.wait_for_unit("postgresql.service")
      original.wait_for_unit("hydra-init.service")

      original.wait_for_unit("hydra-queue-runner.service")
      original.wait_for_unit("hydra-evaluator.service")
      original.wait_for_unit("hydra-server.service")
      original.wait_for_open_port(3000)

      # Create demo data
      original.succeed("hydra-create-user ${username} --role admin --password ${password}")
      original.succeed("${setupJobset}")

      # Wait for builds to succeed
      with subtest("Demo data was set up properly"):
          for i in range(1, 6):
              original.wait_until_succeeds(
                  f"curl -L -s http://localhost:3000/build/{i} -H 'Accept: application/json' "
                  + "|  jq .buildstatus | xargs test 0 -eq"
              )

          # Confirm that email from maintainers exist
          maintainers_old = original.succeed(
              "su -l postgres -c 'psql -d hydra <<< \"select maintainers from builds limit 5;\"'"
          ).split("\n")[2:7]

          for row in maintainers_old:
              row_ = row.strip()
              assert (
                  row_ == "ma27@localhost" or row_ == "ma27@localhost, foo@localhost"
              ), f"Expected correct emails to be present in `builds` table (got '{row_}')!"

      # Perform migration
      original.succeed(
          "${new}/bin/switch-to-configuration test >&2"
      )

      original.wait_for_unit("hydra-init.service")

      out = original.succeed(
          "env HYDRA_UPDATE_MAINTAINERS_BATCH_SIZE=3 hydra-update-maintainers 2>&1"
      )
      assert out.find("Migration seems to be done already") == -1
      print(f"Output from 'hydra-update-maintainers': {out}")

      # Check if new structure for maintainers works
      original.wait_for_open_port(3000)


      def check_table_len(table, expected):
          n = (
              original.succeed(
                  f"su -l postgres -c 'psql -d hydra <<< \"select count(*) from {table};\"'"
              )
              .split("\n")[2]
              .strip()
          )
          assert n == str(expected), f"Expected {expected} entry in {table}, but got {n}!"


      with subtest("Data was migrated properly"):
          check_table_len("maintainers", 2)
          check_table_len("buildsbymaintainers", 6)

          email = original.succeed(
              "curl -L http://localhost:3000/build/1 -H 'Accept: application/json' | jq '.maintainers[0]' | xargs echo"
          ).strip()

          assert email in ["ma27@localhost", "foo@localhost"]

          build_id = (
              original.succeed(
                  "su -l postgres -c 'psql -d hydra <<< \"select b.id from builds b inner join buildsbymaintainers m on m.build_id = b.id group by b.id having count(m) > 1;\"'"
              )
              .split("\n")[2]
              .strip()
          )

          original.succeed(
              f"test 2 -eq \"$(curl -L http://localhost:3000/build/{build_id} -H 'Accept: application/json' | jq '.maintainers|length')\""
          )

      # Check if rerun doesn't do anything
      with subtest("Rerun still doesn't do anything"):
          out = original.succeed("hydra-update-maintainers 2>&1")
          assert out.find("Migration seems to be done already") != -1

      # Finish
      original.shutdown()
    '';
}

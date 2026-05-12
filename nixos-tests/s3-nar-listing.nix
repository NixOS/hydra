{
  system,
  nixpkgs,
  common,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};

  garagePort = 3900;
  garageRpcPort = 3901;
  garageAdminPort = 3902;

  # 32-byte hex RPC secret for garage
  rpcSecret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

  # A derivation that produces a directory with various entry types
  # (regular files, executable files, symlinks, subdirectories) so we
  # can verify the NAR listing captures all of them.
  #
  # The store paths for bash and coreutils are interpolated as literal
  # strings by writeText.  Inside the expression, builtins.storePath
  # re-introduces the string context so that the evaluator on the VM
  # knows the derivation depends on them and the sandbox gets access.
  jobFile = pkgs.writeText "default.nix" ''
    {
      trivial = builtins.derivation {
        name = "trivial";
        system = "${system}";
        builder = "''${builtins.storePath "${pkgs.bash}"}/bin/bash";
        PATH = "''${builtins.storePath "${pkgs.coreutils}"}/bin";
        allowSubstitutes = false;
        preferLocalBuild = true;
        args = [
          "-c"
          "mkdir -p $out/subdir; echo hello > $out/greeting; echo nested > $out/subdir/file; printf '#!/bin/sh\\necho hi\\n' > $out/run.sh; chmod +x $out/run.sh; ln -s greeting $out/link; exit 0"
        ];
      };
    }
  '';

  # The exact NAR listing we expect, used for an exact JSON comparison.
  expectedListing = builtins.toJSON {
    version = 1;
    root = {
      type = "directory";
      entries = {
        greeting = {
          type = "regular";
          executable = false;
          size = 6; # "hello\n"
        };
        link = {
          type = "symlink";
          target = "greeting";
        };
        "run.sh" = {
          type = "regular";
          executable = true;
          size = 18; # printf "#!/bin/sh\necho hi\n" (no extra trailing newline)
        };
        subdir = {
          type = "directory";
          entries = {
            file = {
              type = "regular";
              executable = false;
              size = 7; # "nested\n"
            };
          };
        };
      };
    };
  };
in

(import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).makeTest {
  name = "hydra-s3";

  nodes.s3 =
    { pkgs, ... }:
    {
      services.garage = {
        enable = true;
        package = pkgs.garage;
        settings = {
          replication_factor = 1;
          db_engine = "sqlite";
          rpc_bind_addr = "[::]:${toString garageRpcPort}";
          rpc_secret = rpcSecret;
          s3_api = {
            s3_region = "garage";
            api_bind_addr = "[::]:${toString garagePort}";
            root_domain = ".s3.garage";
          };
          s3_web = {
            bind_addr = "[::]:3903";
            root_domain = ".web.garage";
          };
          admin.api_bind_addr = "[::]:${toString garageAdminPort}";
        };
      };

      networking.firewall.allowedTCPPorts = [
        garagePort
        garageAdminPort
      ];
    };

  nodes.server =
    { pkgs, ... }:
    {
      imports = [ common.serverConfig ];

      services.hydra-queue-runner-dev = {
        settings.remoteStoreAddr = [
          "s3://hydra-cache?endpoint=http://s3:${toString garagePort}&region=garage&write-nar-listing=1&compression=none&scheme=http"
        ];
        awsCredentialsFile = "/var/lib/hydra/queue-runner/.aws-credentials";
      };

      environment.systemPackages = [ pkgs.jq ];
    };

  nodes.builder = common.builderConfig;

  skipLint = true;

  testScript = ''
    import json
    import shlex

    s3.start()
    server.start()
    builder.start()

    # Wait for garage to start
    s3.wait_for_unit("garage.service")
    s3.wait_for_open_port(${toString garagePort})
    s3.wait_for_open_port(${toString garageAdminPort})

    # Configure garage: assign layout, apply, create bucket and key
    node_id = s3.succeed("garage node id -q 2>/dev/null").strip()
    short_id = node_id.split("@")[0][:16] if "@" in node_id else node_id[:16]

    s3.succeed(f"garage layout assign {short_id} -z dc1 -c 1G")

    version = s3.succeed(
        "garage layout show | grep -oP 'apply --version \\K[0-9]+'"
    ).strip()
    s3.succeed(f"garage layout apply --version {version}")

    s3.succeed("garage bucket create hydra-cache")

    key_output = s3.succeed("garage key create hydra-key")
    key_id = ""
    key_secret = ""
    for line in key_output.splitlines():
        if "Key ID" in line:
            key_id = line.split()[-1]
        if "Secret key" in line:
            key_secret = line.split()[-1]

    s3.succeed(
        f"garage bucket allow hydra-cache --read --write --owner --key {key_id}"
    )

    # Write AWS credentials before starting the queue-runner.
    # Uses /var/lib/hydra/ (persistent) rather than /run/ (wiped on restart).
    creds_path = "/var/lib/hydra/queue-runner/.aws-credentials"
    server.wait_for_unit("hydra-init.service")
    server.succeed(
        f"mkdir -p /var/lib/hydra/queue-runner && "
        f"printf '[default]\\naws_access_key_id = {key_id}\\naws_secret_access_key = {key_secret}\\n' > {creds_path} && "
        f"chown hydra-queue-runner:hydra {creds_path} && "
        f"chmod 600 {creds_path}"
    )
    server.succeed("systemctl restart hydra-queue-runner-dev.service")
    server.wait_for_unit("hydra-queue-runner-dev.service")
    builder.wait_for_unit("hydra-queue-builder-dev.service")

    # Create an admin account and project
    server.succeed(
        'su - hydra -c "hydra-create-user root --email-address root@example.org --password foobar --role admin"'
    )

    server.wait_for_unit("hydra-server.service")
    server.wait_for_open_port(3000)

    # Create project and jobset via the API
    server.succeed(
        "mkdir -p /run/jobset && "
        "cp ${jobFile} /run/jobset/default.nix && "
        "chmod -R 755 /run/jobset && "
        "chown -R hydra /run/jobset"
    )

    URL = "http://localhost:3000"
    cookie_jar = "/tmp/hydra-cookie.txt"

    def mycurl(method, path, data=None):
        cmd = f"curl --referer {shlex.quote(URL)} -H 'Accept: application/json' -H 'Content-Type: application/json'"
        cmd += f" -X {method} {shlex.quote(URL + path)}"
        cmd += f" -b {cookie_jar} -c {cookie_jar}"
        if data:
            cmd += f" -d {shlex.quote(json.dumps(data))}"
        return server.succeed(cmd)

    mycurl("POST", "/login", {
        "username": "root",
        "password": "foobar",
    })

    mycurl("PUT", "/project/test", {
        "displayname": "Test",
        "enabled": "1",
        "visible": "1",
    })

    mycurl("PUT", "/jobset/test/trivial", {
        "description": "Trivial",
        "checkinterval": "0",
        "enabled": "1",
        "visible": "1",
        "keepnr": "1",
        "type": 0,
        "nixexprinput": "src",
        "nixexprpath": "default.nix",
        "inputs": {
            "src": {"value": "/run/jobset", "type": "path"},
        },
    })

    # Trigger evaluation
    mycurl("POST", "/api/push?jobsets=test:trivial&force=1")

    # Wait for the build to finish (any status — fail fast instead of hanging)
    server.wait_until_succeeds(
        f'curl -sf {URL}/build/1 -H "Accept: application/json"'
        ' | jq -e ".finished == 1"',
        timeout=120,
    )

    # Check build succeeded
    build_info = json.loads(
        server.succeed(
            f'curl -sf {URL}/build/1 -H "Accept: application/json"'
        )
    )
    if build_info.get("buildstatus") != 0:
        drv = build_info.get("drvpath", "unknown")
        # Dump the nix build log from inside the builder VM
        print(builder.succeed(f"nix-store -l {drv} 2>&1 || true"))
        # Also dump hydra's own build log
        print(
            server.succeed(
                f"find /var/lib/hydra/build-logs -type f -exec bzcat {{}} \\; 2>/dev/null || true"
            )
        )
        raise Exception(
            f"Build failed with status {build_info.get('buildstatus')}, drv={drv}"
        )

    out_path = build_info["buildoutputs"]["out"]["path"]
    store_hash = out_path.split("/")[-1][:32]

    # Wait for the .ls listing to appear in S3 (upload may still be in progress)
    server.wait_until_succeeds(
        f"curl -sf http://s3:${toString garagePort}/hydra-cache/{store_hash}.ls"
        f" --aws-sigv4 'aws:amz:garage:s3'"
        f" -u '{key_id}:{key_secret}'",
        timeout=60,
    )

    # Fetch the .ls listing
    ls_json = server.succeed(
        f"curl -sf http://s3:${toString garagePort}/hydra-cache/{store_hash}.ls"
        f" --aws-sigv4 'aws:amz:garage:s3'"
        f" -u '{key_id}:{key_secret}'"
    )

    # Exact comparison with the expected listing
    expected = json.loads('${expectedListing}')
    actual = json.loads(ls_json)
    assert actual == expected, (
        f"NAR listing mismatch.\n"
        f"Expected:\n{json.dumps(expected, indent=2)}\n"
        f"Actual:\n{json.dumps(actual, indent=2)}"
    )

    builder.shutdown()
    server.shutdown()
    s3.shutdown()
  '';
}

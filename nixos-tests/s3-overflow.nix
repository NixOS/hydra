{
  system,
  nixpkgs,
  common,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};
  inherit (pkgs) lib;

  garagePort = 3900;
  garageRpcPort = 3901;
  garageAdminPort = 3902;

  s3StoreUri = "s3://hydra-cache?compression=none&endpoint=http://s3:${toString garagePort}&region=garage&scheme=http&write-nar-listing=1";
  overflowStoreUri = "s3://hydra-overflow?compression=none&endpoint=http://s3:${toString garagePort}&region=garage&scheme=http&write-nar-listing=1";

  rpcSecret = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

  trivialExpr = ''
    builtins.derivation {
      name = "trivial";
      system = "${system}";
      builder = "''${builtins.storePath "${pkgs.bash}"}/bin/bash";
      PATH = "''${builtins.storePath "${pkgs.coreutils}"}/bin";
      allowSubstitutes = false;
      preferLocalBuild = true;
      args = [
        "-c"
        "mkdir -p $out; echo hello > $out/greeting; exit 0"
      ];
    }
  '';

  jobFile = pkgs.writeText "default.nix" ''
    {
      trivial = ${trivialExpr};
    }
  '';

  # trivial2 references trivial, which forces a copy from the overflow bucket to the default bucket.
  jobFile2 = pkgs.writeText "default2.nix" ''
    let
      trivial = ${trivialExpr};
    in {
      trivial2 = builtins.derivation {
        name = "trivial2";
        system = "${system}";
        builder = "''${builtins.storePath "${pkgs.bash}"}/bin/bash";
        PATH = "''${builtins.storePath "${pkgs.coreutils}"}/bin";
        inref = trivial;
        allowSubstitutes = false;
        preferLocalBuild = true;
        args = [
          "-c"
          "mkdir -p $out; cp $inref/greeting $out/greeting; echo $inref > $out/ref; exit 0"
        ];
      };
    }
  '';
in

(import (nixpkgs + "/nixos/lib/testing-python.nix") { inherit system; }).makeTest {
  name = "hydra-s3-overflow";

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
        settings.remoteStoreAddr = [ s3StoreUri ];
        settings.usePresignedUploads = true;
        settings.forcedSubstituters = [ s3StoreUri ];
        settings.overflowStore = {
          store = overflowStoreUri;
          jobsets = [ "test:overflow" ];
        };
        awsCredentialsFile = "/var/lib/hydra/queue-runner/.aws-credentials";
      };

      environment.systemPackages = [ pkgs.jq ];
    };

  nodes.builder = {
    imports = [ common.builderConfig ];
    services.hydra-queue-builder-dev.useSubstitutes = lib.mkForce true;
    nix.settings.substituters = lib.mkForce [ s3StoreUri ];
  };

  skipLint = true;

  testScript = ''
    import json
    import shlex

    s3.start()
    server.start()
    builder.start()

    s3.wait_for_unit("garage.service")
    s3.wait_for_open_port(${toString garagePort})
    s3.wait_for_open_port(${toString garageAdminPort})

    node_id = s3.succeed("garage node id -q 2>/dev/null").strip()
    short_id = node_id.split("@")[0][:16] if "@" in node_id else node_id[:16]

    s3.succeed(f"garage layout assign {short_id} -z dc1 -c 1G")

    version = s3.succeed(
        "garage layout show | grep -oP 'apply --version \\K[0-9]+'"
    ).strip()
    s3.succeed(f"garage layout apply --version {version}")

    s3.succeed("garage bucket create hydra-cache")
    s3.succeed("garage bucket create hydra-overflow")

    key_output = s3.succeed("garage key create hydra-key")
    key_id = ""
    key_secret = ""
    for line in key_output.splitlines():
        if "Key ID" in line:
            key_id = line.split()[-1]
        if "Secret key" in line:
            key_secret = line.split()[-1]

    for bucket in ("hydra-cache", "hydra-overflow"):
        s3.succeed(
            f"garage bucket allow {bucket} --read --write --owner --key {key_id}"
        )

    def s3_curl(bucket, key, extra=""):
        return (
            f"curl -sf http://s3:${toString garagePort}/{bucket}/{key}"
            f" --aws-sigv4 'aws:amz:garage:s3' -u '{key_id}:{key_secret}' {extra}"
        )

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

    server.succeed(
        'su - hydra -c "hydra-create-user root --email-address root@example.org --password foobar --role admin"'
    )

    server.wait_for_unit("hydra-server.service")
    server.wait_for_open_port(3000)

    URL = "http://localhost:3000"
    cookie_jar = "/tmp/hydra-cookie.txt"

    def mycurl(method, path, data=None):
        cmd = f"curl --referer {shlex.quote(URL)} -H 'Accept: application/json' -H 'Content-Type: application/json'"
        cmd += f" -X {method} {shlex.quote(URL + path)}"
        cmd += f" -b {cookie_jar} -c {cookie_jar}"
        if data:
            cmd += f" -d {shlex.quote(json.dumps(data))}"
        return server.succeed(cmd)

    def make_jobset(name, job_file):
        src = f"/run/jobset-{name}"
        server.succeed(
            f"mkdir -p {src} && cp {job_file} {src}/default.nix && "
            f"chmod -R 755 {src} && chown -R hydra {src}"
        )
        mycurl("PUT", f"/jobset/test/{name}", {
            "description": name,
            "checkinterval": "0",
            "enabled": "1",
            "visible": "1",
            "keepnr": "1",
            "type": 0,
            "nixexprinput": "src",
            "nixexprpath": "default.nix",
            "inputs": {"src": {"value": src, "type": "path"}},
        })
        mycurl("POST", f"/api/push?jobsets=test:{name}&force=1")

    def wait_build(build_id):
        server.wait_until_succeeds(
            f'curl -sf {URL}/build/{build_id} -H "Accept: application/json"'
            ' | jq -e ".finished == 1"',
            timeout=180,
        )
        info = json.loads(
            server.succeed(
                f'curl -sf {URL}/build/{build_id} -H "Accept: application/json"'
            )
        )
        assert info.get("buildstatus") == 0, f"build {build_id} failed: {info}"
        return info

    mycurl("POST", "/login", {"username": "root", "password": "foobar"})
    mycurl("PUT", "/project/test", {
        "displayname": "Test",
        "enabled": "1",
        "visible": "1",
    })

    # trivial from the overflow jobset must land in the overflow bucket only.
    make_jobset("overflow", "${jobFile}")
    build1 = wait_build(1)
    trivial_hash = build1["buildoutputs"]["out"]["path"].split("/")[-1][:32]

    server.wait_until_succeeds(
        s3_curl("hydra-overflow", f"{trivial_hash}.narinfo"), timeout=60
    )
    server.fail(s3_curl("hydra-cache", f"{trivial_hash}.narinfo"))

    # trivial2 references trivial, forcing a copy to the default bucket.
    make_jobset("main", "${jobFile2}")
    build2 = wait_build(2)
    trivial2_hash = build2["buildoutputs"]["out"]["path"].split("/")[-1][:32]

    server.wait_until_succeeds(
        s3_curl("hydra-cache", f"{trivial2_hash}.narinfo"), timeout=60
    )

    # The copy brought trivial's NAR and listing along.
    narinfo = server.succeed(s3_curl("hydra-cache", f"{trivial_hash}.narinfo"))
    nar_url = next(
        l.split(":", 1)[1].strip() for l in narinfo.splitlines() if l.startswith("URL:")
    )
    server.succeed(s3_curl("hydra-cache", nar_url, extra="-I"))
    server.succeed(s3_curl("hydra-cache", f"{trivial_hash}.ls"))

    server.fail(s3_curl("hydra-overflow", f"{trivial2_hash}.narinfo"))

    builder.shutdown()
    server.shutdown()
    s3.shutdown()
  '';
}

# End-to-end test for per-build limits: meta.maxSilent, meta.timeout,
# maxLogSize and maxOutputSize. Also checks that meta.maxSilent overrides the
# queue-runner's maxSilentTime default rather than being capped by it.
{
  system,
  nixpkgs,
  common,
}:

let
  pkgs = nixpkgs.legacyPackages.${system};

  maxLogSize = 65536; # 64 KiB
  maxOutputSize = 1048576; # 1 MiB

  # The jobs need sleep/dd. The builder VM shares the host store, but the
  # build sandbox would hide paths that are not proper inputs, so the builder
  # node runs with sandbox disabled and the jobs use busybox from the host
  # store via PATH.
  jobset = pkgs.writeText "jobset.nix" ''
    let
      mkJob = { name, script, meta ? { } }: derivation {
        inherit name;
        system = "${system}";
        builder = "/bin/sh";
        args = [ "-eu" "-c" ("export PATH=${pkgs.busybox}/bin; " + script) ];
        allowSubstitutes = false;
        preferLocalBuild = true;
      } // { inherit meta; };
    in
    {
      # Silent longer than maxSilent: times out.
      silent_kills = mkJob {
        name = "silent-kills";
        script = "sleep 600; echo unreachable > $out";
        meta.maxSilent = 5;
      };

      # Silent for 15s; maxSilent = 600 must win over the 5s queue-runner default.
      silent_survives = mkJob {
        name = "silent-survives";
        script = "sleep 15; echo done > $out";
        meta.maxSilent = 600;
      };

      # Never silent, but exceeds meta.timeout: times out.
      timeout_kills = mkJob {
        name = "timeout-kills";
        script = "i=0; while [ $i -lt 600 ]; do echo tick $i; sleep 1; i=$((i + 1)); done; echo unreachable > $out";
        meta.timeout = 5;
      };

      # Logs more than maxLogSize.
      log_limit = mkJob {
        name = "log-limit";
        script = "i=0; while [ $i -lt 10000 ]; do echo 'this line pads the build log to exceed the configured limit'; i=$((i + 1)); done; echo done > $out";
      };

      # Output larger than maxOutputSize.
      output_limit = mkJob {
        name = "output-limit";
        script = "dd if=/dev/zero of=$out bs=1024 count=5120";
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

    mycurl -X PUT $URL/project/limits -b hydra-cookie.txt -d '{
      "displayname": "Limits",
      "enabled": "1",
      "visible": "1"
    }'

    mycurl -X PUT $URL/jobset/limits/default -b hydra-cookie.txt -d '{
      "description": "build limits regression",
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
  name = "hydra-limits";
  nodes.server = {
    imports = [ common.serverConfig ];
    services.hydra-queue-runner-dev.settings = {
      maxSilentTime = 5;
      inherit maxLogSize maxOutputSize;
    };
  };
  nodes.builder = {
    imports = [ common.builderConfig ];
    nix.settings.sandbox = false;
  };
  testScript = ''
    import json

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

    def wait_finished(job):
        # /api/latestbuilds returns finished builds regardless of status.
        url = f"http://localhost:3000/api/latestbuilds?nr=1&project=limits&jobset=default&job={job}"
        status = None

        def finished(_) -> bool:
            nonlocal status
            builds = json.loads(server.succeed(f"curl -Lf -s '{url}'"))
            if not builds:
                return False
            status = builds[0]["buildstatus"]
            return True

        with server.nested(f"waiting for finished build of {job}"):
            retry(finished, timeout_seconds=300)
        return status

    # 0 = success, 7 = timed out, 10 = log limit, 11 = output size limit
    expected = {
        "silent_kills": 7,
        "timeout_kills": 7,
        "log_limit": 10,
        "output_limit": 11,
        "silent_survives": 0,
    }

    for job, want in expected.items():
        got = wait_finished(job)
        assert got == want, f"{job}: expected buildstatus {want}, got {got}"
  '';
}

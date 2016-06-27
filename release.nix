{ hydraSrc ? { outPath = ./.; revCount = 1234; rev = "abcdef"; }
, officialRelease ? false
, shell ? false
}:

with import <nixpkgs/lib>;

let

  pkgs = import <nixpkgs> {};

  genAttrs' = genAttrs [ "x86_64-linux" /* "i686-linux" */ ];

  hydraServer = hydraPkg:
    { config, pkgs, ... }:
    { imports = [ ./hydra-module.nix ];

      virtualisation.memorySize = 1024;
      virtualisation.writableStore = true;

      services.hydra.enable = true;
      services.hydra.package = hydraPkg;
      services.hydra.hydraURL = "http://hydra.example.org";
      services.hydra.notificationSender = "admin@hydra.example.org";

      services.postgresql.enable = true;
      services.postgresql.package = pkgs.postgresql92;

      environment.systemPackages = [ pkgs.perlPackages.LWP pkgs.perlPackages.JSON ];
    };

  version = builtins.readFile ./version + "." + toString hydraSrc.revCount + "." + hydraSrc.rev;

in

rec {

  build = genAttrs' (system:
    import ./default.nix {
      src = hydraSrc;
      pkgs = import <nixpkgs> { inherit system; };
      inherit version;
    });

  tests.install = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    simpleTest {
      machine = hydraServer build.${system};
      testScript =
        ''
          $machine->waitForJob("hydra-init");
          $machine->waitForJob("hydra-server");
          $machine->waitForJob("hydra-evaluator");
          $machine->waitForJob("hydra-queue-runner");
          $machine->waitForOpenPort("3000");
          $machine->succeed("curl --fail http://localhost:3000/");
        '';
    });

  tests.api = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    simpleTest {
      machine = hydraServer build.${system};
      testScript =
        let dbi = "dbi:Pg:dbname=hydra;user=root;"; in
        ''
          $machine->waitForJob("hydra-init");

          # Create an admin account and some other state.
          $machine->succeed
              ( "su - hydra -c \"hydra-create-user root --email-address 'alice\@example.org' --password foobar --role admin\""
              , "mkdir /run/jobset /tmp/nix"
              , "chmod 755 /run/jobset /tmp/nix"
              , "cp ${./tests/api-test.nix} /run/jobset/default.nix"
              , "chmod 644 /run/jobset/default.nix"
              , "chown -R hydra /run/jobset /tmp/nix"
              );

          $machine->succeed("systemctl stop hydra-evaluator hydra-queue-runner");
          $machine->waitForJob("hydra-server");
          $machine->waitForOpenPort("3000");

          # Run the API tests.
          $machine->mustSucceed("su - hydra -c 'perl ${./tests/api-test.pl}' >&2");
        '';
  });

  /*
  tests.s3backup = genAttrs' (system:
    with import <nixpkgs/nixos/lib/testing.nix> { inherit system; };
    let hydra = build.${system}
    simpleTest {
      machine =
        { config, pkgs, ... }:
        { services.postgresql.enable = true;
          services.postgresql.package = pkgs.postgresql92;
          environment.systemPackages = [ hydra pkgs.rubyLibs.fakes3 ];
          virtualisation.memorySize = 2047;
          boot.kernelPackages = pkgs.linuxPackages_3_10;
          virtualisation.writableStore = true;
          networking.extraHosts = ''
            127.0.0.1 hydra.s3.amazonaws.com
          '';
        };

      testScript =
        ''
          $machine->waitForJob("postgresql");

          # Initialise the database and the state.
          $machine->succeed
              ( "createdb -O root hydra"
              , "psql hydra -f ${hydra}/libexec/hydra/sql/hydra-postgresql.sql"
              , "mkdir /var/lib/hydra"
              , "mkdir /tmp/jobs"
              , "cp ${./tests/s3-backup-test.pl} /tmp/s3-backup-test.pl"
              , "cp ${./tests/api-test.nix} /tmp/jobs/default.nix"
              );

          # start fakes3
          $machine->succeed("fakes3 --root /tmp/s3 --port 80 &>/dev/null &");
          $machine->waitForOpenPort("80");

          $machine->succeed("cd /tmp && LOGNAME=root AWS_ACCESS_KEY_ID=foo AWS_SECRET_ACCESS_KEY=bar HYDRA_DBI='dbi:Pg:dbname=hydra;user=root;' HYDRA_CONFIG=${./tests/s3-backup-test.config} perl -I ${hydra}/libexec/hydra/lib -I ${hydra.perlDeps}/lib/perl5/site_perl ./s3-backup-test.pl >&2");
        '';
  });
  */
}

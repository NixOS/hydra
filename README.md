To quickly start hacking on Hydra, run:

    $ nix-shell --command 'setup-dev-env; return'

This will run the following commands:

    $ bootstrap
    $ nix-shell
    $ ./configure $configureFlags --prefix=/opt/hydra
    $ make
    $ setup-database
    $ hydra-create-user admin --password admin --role admin

The `setup-database` command is used for setting up a temporary database living
in the `inst/database` subdirectory of the project root. It also sets up the
required environment variables `HYDRA_HOME`, `HYDRA_DATA` and `HYDRA_DBI` as
well as the `PG*` environment variables so that if you want to start a database
shell it's a matter of simply running:

    $ pgsql

Or, if you just want to build from source (on `x86_64-linux`):

    $ nix-build -A build.x86_64-linux release.nix

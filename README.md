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

If you want to do all of the setup together with starting the Hydra web server,
you can do that as well in one command:

    $ nix-shell --command 'setup-dev-env && hydra-server'

The shell and the server will go down once you press `CTRL+C`. If this is not
desired, you can append `; return` to the command so that you will return to
the `nix-shell` after you press `CTRL+C`.

Or, if you just want to build from source (on `x86_64-linux`):

    $ nix-build -A build.x86_64-linux release.nix

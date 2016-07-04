To quickly start hacking on Hydra, run:

    $ nix-shell --command 'setup-dev-env; return'

This will run the following commands:

    $ bootstrap
    $ nix-shell
    $ ./configure $configureFlags --prefix=/opt/hydra
    $ make
    $ setup-database

The `setup-database` command is used for setting up a temporary database living
in the `inst/database` subdirectory of the project root. It also sets up the
required environment variables `HYDRA_HOME`, `HYDRA_DATA` and `HYDRA_DBI`.

Or, if you just want to build from source (on `x86_64-linux`):

    $ nix-build -A build.x86_64-linux release.nix

Hacking
=======

This section provides some notes on how to hack on Hydra. To get the
latest version of Hydra from GitHub:

    $ git clone git://github.com/NixOS/hydra.git
    $ cd hydra

To build it and its dependencies:

    $ nix-build release.nix -A build.x86_64-linux

To build all dependencies and start a shell in which all environment
variables (such as PERL5LIB) are set up so that those dependencies can
be found:

    $ nix-shell

To build Hydra, you should then do:

    [nix-shell]$ ./bootstrap
    [nix-shell]$ configurePhase
    [nix-shell]$ make

You can run the Hydra web server in your source tree as follows:

    $ ./src/script/hydra-server

You can run Hydra's test suite with the following:

    [nix-shell]$ make check
    [nix-shell]$ # to run as many tests as you have cores:
    [nix-shell]$ make check YATH_JOB_COUNT=$NIX_BUILD_CORES
    [nix-shell]$ # or run yath directly:
    [nix-shell]$ yath test
    [nix-shell]$ # to run as many tests as you have cores:
    [nix-shell]$ yath test -j $NIX_BUILD_CORES

When using `yath` instead of `make check`, ensure you have run `make`
in the root of the repository at least once.

**Warning**: Currently, the tests can fail
if run with high parallelism [due to an issue in
`Test::PostgreSQL`](https://github.com/TJC/Test-postgresql/issues/40)
causing database ports to collide.

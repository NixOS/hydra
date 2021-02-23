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

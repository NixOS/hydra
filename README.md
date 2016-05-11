To start hacking on Hydra, run:

    $ bootstrap
    $ nix-shell
    $ ./configure $configureFlags --prefix=/opt/hydra
    $ make
    $ make install

Or, if you just want to build from source (on x86_64-linux):

    $ nix-build -A build.x86_64-linux release.nix

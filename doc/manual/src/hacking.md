# Hacking

This section provides some notes on how to hack on Hydra. To get the
latest version of Hydra from GitHub:

```console
$ git clone git://github.com/NixOS/hydra.git
$ cd hydra
```

To enter a shell in which all environment variables (such as `PERL5LIB`)
and dependencies can be found:

```console
$ nix develop
```

To build Hydra, you should then do:

```console
$ mesonConfigurePhase
$ ninja
```

You start a local database, the webserver, and other components with
foreman:

```console
$ ninja -C build
$ foreman start
```

The Hydra interface will be available on port 63333, with an admin user named "alice" with password "foobar"

You can run just the Hydra web server in your source tree as follows:

```console
$ ./src/script/hydra-server
```

You can run Hydra's test suite with the following:

```console
$ meson test
# to run as many tests as you have cores:
$ YATH_JOB_COUNT=$NIX_BUILD_CORES meson test
```

**Warning**: Currently, the tests can fail
if run with high parallelism [due to an issue in
`Test::PostgreSQL`](https://github.com/TJC/Test-postgresql/issues/40)
causing database ports to collide.

## Working on the Manual

By default, `foreman start` runs mdbook in "watch" mode. mdbook listens
at [http://localhost:63332/](http://localhost:63332/), and
will reload the page every time you save.

## Building

To build Hydra and its dependencies:

```console
$ nix build .#packages.x86_64-linux.default
```

## Development Tasks

### Connecting to the database

Assuming you're running the default configuration with `foreman start`,
open an interactive session with Postgres via:

```console
$ psql --host localhost --port 64444 hydra
```

### Runinng the builder locally

For `hydra-queue-runner` to successfully build locally, your
development user will need to be "trusted" by your Nix store.

Add yourself to the `trusted_users` option of `/etc/nix/nix.conf`.

On NixOS:

```nix
{
  nix.settings.trusted-users = [ "YOURUSER" ];
}
```

Off NixOS, change `/etc/nix/nix.conf`:

```conf
trusted-users = root YOURUSERNAME
```

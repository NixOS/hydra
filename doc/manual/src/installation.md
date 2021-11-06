Installation
============

This chapter explains how to install Hydra on your own build farm
server.

Prerequisites
-------------

To install and use Hydra you need to have installed the following
dependencies:

-   Nix

-   PostgreSQL

-   many Perl packages, notably Catalyst, EmailSender, and NixPerl (see
    the [Hydra expression in
    Nixpkgs](https://github.com/NixOS/hydra/blob/master/release.nix) for
    the complete list)

At the moment, Hydra runs only on GNU/Linux (*i686-linux* and
*x86\_64\_linux*).

For small projects, Hydra can be run on any reasonably modern machine.
For individual projects you can even run Hydra on a laptop. However, the
charm of a buildfarm server is usually that it operates without
disturbing the developer\'s working environment and can serve releases
over the internet. In conjunction you should typically have your source
code administered in a version management system, such as subversion.
Therefore, you will probably want to install a server that is connected
to the internet. To scale up to large and/or many projects, you will
need at least a considerable amount of diskspace to store builds. Since
Hydra can schedule multiple simultaneous build jobs, it can be useful to
have a multi-core machine, and/or attach multiple build machines in a
network to the central Hydra server.

Of course we think it is a good idea to use the
[NixOS](http://nixos.org/nixos) GNU/Linux distribution for your
buildfarm server. But this is not a requirement. The Nix software
deployment system can be installed on any GNU/Linux distribution in
parallel to the regular package management system. Thus, you can use
Hydra on a Debian, Fedora, SuSE, or Ubuntu system.

Getting Nix
-----------

If your server runs NixOS you are all set to continue with installation
of Hydra. Otherwise you first need to install Nix. The latest stable
version can be found one [the Nix web
site](http://nixos.org/nix/download.html), along with a manual, which
includes installation instructions.

Installation
------------

The latest development snapshot of Hydra can be installed by visiting
the URL
[`http://hydra.nixos.org/view/hydra/unstable`](http://hydra.nixos.org/view/hydra/unstable)
and using the one-click install available at one of the build pages. You
can also install Hydra through the channel by performing the following
commands:

    nix-channel --add http://hydra.nixos.org/jobset/hydra/master/channel/latest
    nix-channel --update
    nix-env -i hydra

Command completion should reveal a number of command-line tools from
Hydra, such as `hydra-queue-runner`.

Creating the database
---------------------

Hydra stores its results in a PostgreSQL database.

To setup a PostgreSQL database with *hydra* as database name and user
name, issue the following commands on the PostgreSQL server:

```console
createuser -S -D -R -P hydra
createdb -O hydra hydra
```

Note that *\$prefix* is the location of Hydra in the nix store.

Hydra uses an environment variable to know which database should be
used, and a variable which point to a location that holds some state. To
set these variables for a PostgreSQL database, add the following to the
file `~/.profile` of the user running the Hydra services.

```console
export HYDRA_DBI="dbi:Pg:dbname=hydra;host=dbserver.example.org;user=hydra;"
export HYDRA_DATA=/var/lib/hydra
```

You can provide the username and password in the file `~/.pgpass`, e.g.

```
dbserver.example.org:*:hydra:hydra:password
```

Make sure that the *HYDRA\_DATA* directory exists and is writable for
the user which will run the Hydra services.

Having set these environment variables, you can now initialise the
database by doing:

```console
hydra-init
```

To create projects, you need to create a user with *admin* privileges.
This can be done using the command `hydra-create-user`:

```console
$ hydra-create-user alice --full-name 'Alice Q. User' \
    --email-address 'alice@example.org' --password foobar --role admin
```

Additional users can be created through the web interface.

Upgrading
---------

If you\'re upgrading Hydra from a previous version, you should do the
following to perform any necessary database schema migrations:

```console
hydra-init
```

Getting Started
---------------

To start the Hydra web server, execute:

```console
hydra-server
```

When the server is started, you can browse to [http://localhost:3000/]()
to start configuring your Hydra instance.

The `hydra-server` command launches the web server. There are two other
processes that come into play:

-   The
    evaluator
    is responsible for periodically evaluating job sets, checking out
    their dependencies off their version control systems (VCS), and
    queueing new builds if the result of the evaluation changed. It is
    launched by the
    hydra-evaluator
    command.
-   The
    queue runner
    launches builds (using Nix) as they are queued by the evaluator,
    scheduling them onto the configured Nix hosts. It is launched using
    the
    hydra-queue-runner
    command.

All three processes must be running for Hydra to be fully functional,
though it\'s possible to temporarily stop any one of them for
maintenance purposes, for instance.

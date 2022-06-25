Creating and Managing Projects
==============================

Once Hydra is installed and running, the next step is to add projects to
the build farm. We follow the example of the [Patchelf
project](http://nixos.org/patchelf.html), a software tool written in C
and using the GNU Build System (GNU Autoconf and GNU Automake).

Log in to the web interface of your Hydra installation using the user
name and password you inserted in the database (by default, Hydra\'s web
server listens on [`localhost:3000`](http://localhost:3000/)). Then
follow the \"Create Project\" link to create a new project.

Project Information
-------------------

A project definition consists of some general information and a set of
job sets. The general information identifies a project, its owner, and
current state of activity. Here\'s what we fill in for the patchelf
project:

    Identifier: patchelf

The *identifier* is the identity of the project. It is used in URLs and
in the names of build results.

The identifier should be a unique name (it is the primary database key
for the project table in the database). If you try to create a project
with an already existing identifier you\'d get an error message from the
database. So try to create the project after entering just the general
information to figure out if you have chosen a unique name. Job sets can
be added once the project has been created.

    Display name: Patchelf

The *display name* is used in menus.

    Description: A tool for modifying ELF binaries

The *description* is used as short documentation of the nature of the
project.

    Owner: eelco

The *owner* of a project can create and edit job sets.

    Enabled: Yes

Only if the project is *enabled* are builds performed.

Once created there should be an entry for the project in the sidebar. Go
to the project page for the
[Patchelf](http://localhost:3000/project/patchelf) project.

Job Sets
--------

A project can consist of multiple *job sets* (hereafter *jobsets*),
separate tasks that can be built separately, but may depend on each
other (without cyclic dependencies, of course). Go to the
[Edit](http://localhost:3000/project/patchelf/edit) page of the Patchelf
project and \"Add a new jobset\" by providing the following
\"Information\":

    Identifier:     trunk
    Description:    Trunk
    Nix expression: release.nix in input patchelfSrc

This states that in order to build the `trunk` jobset, the Nix
expression in the file `release.nix`, which can be obtained from input
`patchelfSrc`, should be evaluated. (We\'ll have a look at `release.nix`
later.)

To realize a job we probably need a number of inputs, which can be
declared in the table below. As many inputs as required can be added.
For patchelf we declare the following inputs.

    patchelfSrc
    'Git checkout' https://github.com/NixOS/patchelf

    nixpkgs 'Git checkout' https://github.com/NixOS/nixpkgs

    officialRelease   Boolean false

    system   String value "i686-linux"

Building Jobs
-------------

Build Recipes
-------------

Build jobs and *build recipes* for a jobset are specified in a text file
written in the [Nix language](http://nixos.org/nix/). The recipe is
actually called a *Nix expression* in Nix parlance. By convention this
file is often called `release.nix`.

The `release.nix` file is typically kept under version control, and the
repository that contains it one of the build inputs of the
corresponding--often called `hydraConfig` by convention. The repository
for that file and the actual file name are specified on the web
interface of Hydra under the `Setup` tab of the jobset\'s overview page,
under the `Nix
      expression` heading. See, for example, the [jobset overview
page](http://hydra.nixos.org/jobset/patchelf/trunk) of the PatchELF
project, and [the corresponding Nix
file](https://github.com/NixOS/patchelf/blob/master/release.nix).

Knowledge of the Nix language is recommended, but the example below
should already give a good idea of how it works:

    let
      pkgs = import <nixpkgs> {}; ① 

      jobs = rec { ②

        tarball = ③
          pkgs.releaseTools.sourceTarball { ④
            name = "hello-tarball";
            src = <hello>; ⑤
            buildInputs = (with pkgs; [ gettext texLive texinfo ]);
          };

        build = ⑥
          { system ? builtins.currentSystem }:  ⑦

          let pkgs = import <nixpkgs> { inherit system; }; in
          pkgs.releaseTools.nixBuild { ⑧
            name = "hello";
            src = jobs.tarball;
            configureFlags = [ "--disable-silent-rules" ];
          };
      };
    in
      jobs ⑨
          

This file shows what a `release.nix` file for
[GNU Hello](http://www.gnu.org/software/hello/) would look like.
GNU Hello is representative of many GNU and non-GNU free software
projects:

-   it uses the GNU Build System, namely GNU Autoconf, and GNU Automake;
    for users, it means it can be installed using the
    usual
    ./configure && make install
    procedure
    ;
-   it uses Gettext for internationalization;
-   it has a Texinfo manual, which can be rendered as PDF with TeX.

The file defines a jobset consisting of two jobs: `tarball`, and
`build`. It contains the following elements (referenced from the figure
by numbers):

1.  This defines a variable `pkgs` holding the set of packages provided
    by [Nixpkgs](http://nixos.org/nixpkgs/).

    Since `nixpkgs` appears in angle brackets, there must be a build
    input of that name in the Nix search path. In this case, the web
    interface should show a `nixpkgs` build input, which is a checkout
    of the Nixpkgs source code repository; Hydra then adds this and
    other build inputs to the Nix search path when evaluating
    `release.nix`.

2.  This defines a variable holding the two Hydra jobs--an *attribute
    set* in Nix.

3.  This is the definition of the first job, named `tarball`. The
    purpose of this job is to produce a usable source code tarball.

4.  The `tarball` job calls the `sourceTarball` function, which
    (roughly) runs `autoreconf && ./configure &&
                make dist` on the checkout. The `buildInputs` attribute
    specifies additional software dependencies for the job.
    
    > The package names used in `buildInputs`--e.g., `texLive`--are the
    > names of the *attributes* corresponding to these packages in
    > Nixpkgs, specifically in the
    > [`all-packages.nix`](https://github.com/NixOS/nixpkgs/blob/master/pkgs/top-level/all-packages.nix)
    > file. See the section entitled "Package Naming" in the Nixpkgs
    > manual for more information.

5.  The `tarball` jobs expects a `hello` build input to be available in
    the Nix search path. Again, this input is passed by Hydra and is
    meant to be a checkout of GNU Hello\'s source code repository.

6.  This is the definition of the `build` job, whose purpose is to build
    Hello from the tarball produced above.

7.  The `build` function takes one parameter, `system`, which should be
    a string defining the Nix system type--e.g., `"x86_64-linux"`.
    Additionally, it refers to `jobs.tarball`, seen above.

    Hydra inspects the formal argument list of the function (here, the
    `system` argument) and passes it the corresponding parameter
    specified as a build input on Hydra\'s web interface. Here, `system`
    is passed by Hydra when it calls `build`. Thus, it must be defined
    as a build input of type string in Hydra, which could take one of
    several values.

    The question mark after `system` defines the default value for this
    argument, and is only useful when debugging locally.

8.  The `build` job calls the `nixBuild` function, which unpacks the
    tarball, then runs `./configure && make
                && make check && make install`.

9.  Finally, the set of jobs is returned to Hydra, as a Nix attribute
    set.

Building from the Command Line
------------------------------

It is often useful to test a build recipe, for instance before it is
actually used by Hydra, when testing changes, or when debugging a build
issue. Since build recipes for Hydra jobsets are just plain Nix
expressions, they can be evaluated using the standard Nix tools.

To evaluate the `tarball` jobset of the above example, just
run:

```console
$ nix-build release.nix -A tarball
```

However, doing this with the example as is will probably
yield an error like this:

    error: user-thrown exception: file `hello' was not found in the Nix search path (add it using $NIX_PATH or -I)

The error is self-explanatory. Assuming `$HOME/src/hello` points to a
checkout of Hello, this can be fixed this way:

```console
$ nix-build -I ~/src release.nix -A tarball
```

Similarly, the `build` jobset can be evaluated:

```console
$ nix-build -I ~/src release.nix -A build
```

The `build` job reuses the result of the `tarball` job, rebuilding it
only if it needs to.

Adding More Jobs
----------------

The example illustrates how to write the most basic
jobs, `tarball` and `build`. In practice, much more can be done by using
features readily provided by Nixpkgs or by creating new jobs as
customizations of existing jobs.

For instance, test coverage report for projects compiled with GCC can be
automatically generated using the `coverageAnalysis` function provided
by Nixpkgs instead of `nixBuild`. Back to our GNU Hello example, we can
define a `coverage` job that produces an HTML code coverage report
directly readable from the corresponding Hydra build page:

    coverage =
      { system ? builtins.currentSystem }:

      let pkgs = import nixpkgs { inherit system; }; in
      pkgs.releaseTools.coverageAnalysis {
        name = "hello";
        src = jobs.tarball;
        configureFlags = [ "--disable-silent-rules" ];
      };

As can be seen, the only difference compared to `build` is the use of
`coverageAnalysis`.

Nixpkgs provides many more build tools, including the ability to run
build in virtual machines, which can themselves run another GNU/Linux
distribution, which allows for the creation of packages for these
distributions. Please see [the `pkgs/build-support/release`
directory](https://github.com/NixOS/nixpkgs/tree/master/pkgs/build-support/release)
of Nixpkgs for more. The NixOS manual also contains information about
whole-system testing in virtual machine.

Now, assume we want to build Hello with an old version of GCC, and with
different `configure` flags. A new `build_exotic` job can be written
that simply *overrides* the relevant arguments passed to `nixBuild`:

    build_exotic =
      { system ? builtins.currentSystem }:

      let
        pkgs = import nixpkgs { inherit system; };
        build = jobs.build { inherit system; };
      in
        pkgs.lib.overrideDerivation build (attrs: {
          buildInputs = [ pkgs.gcc33 ];
          preConfigure = "gcc --version";
          configureFlags =
            attrs.configureFlags ++ [ "--disable-nls" ];
        });

The `build_exotic` job reuses `build` and overrides some of its
arguments: it adds a dependency on GCC 3.3, a pre-configure phase that
runs `gcc --version`, and adds the `--disable-nls` configure flags.

This customization mechanism is very powerful. For instance, it can be
used to change the way Hello and *all* its dependencies--including the C
library and compiler used to build it--are built. See the Nixpkgs manual
for more.

Declarative Projects
--------------------

see this [chapter](./plugins/declarative-projects.md)

Email Notifications
-------------------

Hydra can send email notifications when the status of a build changes.
This provides immediate feedback to maintainers or committers when a
change causes build failures.

The feature can be turned on by adding the following line to `hydra.conf`

``` conf
email_notification = 1
```

By default, Hydra only sends email notifications if a previously successful
build starts to fail. In order to force Hydra to send an email for each build
(including e.g. successful or cancelled ones), the environment variable
`HYDRA_FORCE_SEND_MAIL` can be declared:

``` nix
services.hydra-dev.extraEnv.HYDRA_FORCE_SEND_MAIL = "1";
```

SASL Authentication for the email address that's used to send notifications
can be configured like this:

``` conf
EMAIL_SENDER_TRANSPORT_sasl_username=hydra@example.org
EMAIL_SENDER_TRANSPORT_sasl_password=verysecret
EMAIL_SENDER_TRANSPORT_port=587
EMAIL_SENDER_TRANSPORT_ssl=starttls
```

Further information about these environment variables can be found at the
[MetaCPAN documentation of `Email::Sender::Manual::QuickStart`](https://metacpan.org/pod/Email::Sender::Manual::QuickStart#specifying-transport-in-the-environment).

It's recommended to not put this in `services.hydra-dev.extraEnv` as this would
leak the secrets into the Nix store. Instead, it should be written into an
environment file and configured like this:

``` nix
{ systemd.services.hydra-notify = {
    serviceConfig.EnvironmentFile = "/etc/secrets/hydra-mail-cfg";
  };
}
```

The simplest approach to enable Email Notifications is to use the ssmtp
package, which simply hands off the emails to another SMTP server. For
details on how to configure ssmtp, see the documentation for the
`networking.defaultMailServer` option. To use ssmtp for the Hydra email
notifications, add it to the path option of the Hydra services in your
`/etc/nixos/configuration.nix` file:

    systemd.services.hydra-queue-runner.path = [ pkgs.ssmtp ];
    systemd.services.hydra-server.path = [ pkgs.ssmtp ];

Gitea Integration
-----------------

Hydra can notify Git servers (such as [GitLab](https://gitlab.com/), [GitHub](https://github.com)
or [Gitea](https://gitea.io/en-us/)) about the result of a build from a Git checkout.

This section describes how it can be implemented for `gitea`, but the approach for `gitlab` is
analogous:

* [Obtain an API token for your user](https://docs.gitea.io/en-us/api-usage/#authentication)
* Add it to your `hydra.conf` like this:
  ``` nix
  {
    services.hydra-dev.extraConfig = ''
      <gitea_authorization>
      your_username=your_token
      </gitea_authorization>
    '';
  }
  ```

* For a jobset with a `Git`-input which points to a `gitea`-instance, add the following
  additional inputs:

  | Type           | Name                | Value                              |
  | -------------- | ------------------- | ---------------------------------- |
  | `String value` | `gitea_repo_name`   | *Name of the repository to build*  |
  | `String value` | `gitea_repo_owner`  | *Owner of the repository*          |
  | `String value` | `gitea_status_repo` | *Name of the `Git checkout` input* |
  | `String value` | `gitea_http_url`    | *Public URL of `gitea`*, optional  |

Content-addressed derivations
-----------------------------

Hydra can to a certain extent use the [`ca-derivations` experimental Nix feature](https://github.com/NixOS/rfcs/pull/62).
To use it, make sure that the Nix version you use is at least as recent as the one used in hydra's flake.

Be warned that this support is still highly experimental, and anything beyond the basic functionality might be broken at that point.

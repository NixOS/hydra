# Hydra

[![CI](https://github.com/NixOS/hydra/workflows/Test/badge.svg)](https://github.com/NixOS/hydra/actions)

Hydra is a [Continuous Integration](https://en.wikipedia.org/wiki/Continuous_integration) service for [Nix](https://nixos.org/nix) based projects.

## Installation And Setup

**Note**: The instructions provided below are intended to enable new users to get a simple, local installation up and running. They are by no means sufficient for running a production server, let alone a public instance.

### Enabling The Service
Running Hydra is currently only supported on NixOS. The [hydra module](https://github.com/NixOS/nixpkgs/blob/release-20.03/nixos/modules/services/continuous-integration/hydra/default.nix) allows for an easy setup. The following configuration can be used for a simple setup that performs all builds on _localhost_ (Please refer to the [Options page](https://nixos.org/nixos/options.html#services.hydra) for all available options):

```nix
{
  services.hydra = {
    enable = true;
    hydraURL = "http://localhost:3000";
    notificationSender = "hydra@localhost";
    buildMachinesFiles = [];
    useSubstitutes = true;
  };
}
```
### Creating An Admin User
Once the Hydra service has been configured as above and activate you should already be able to access the UI interface at the specified URL. However some actions require an admin user which has to be created first:

```
$ su - hydra
$ hydra-create-user <USER> --full-name '<NAME>' \
    --email-address '<EMAIL>' --password-prompt --role admin
```

Afterwards you should be able to log by clicking on "_Sign In_" on the top right of the web interface using the credentials specified by `hydra-create-user`. Once you are logged in you can click "_Admin -> Create Project_" to configure your first project.

### Creating A Simple Project And Jobset
In order to evaluate and build anything you need to create _projects_ that contain _jobsets_. Hydra supports imperative and declarative projects and many different configurations. The steps below will guide you through the required steps to creating a minimal imperative project configuration.

#### Creating A Project
Log in as administrator, click "_Admin_" and select "_Create project_". Fill the form as follows:

- **Identifier**: `hello`
- **Display name**: `hello`
- **Description**: `hello project`

Click "_Create project_".

#### Creating A Jobset
After creating a project you are forwarded to the project page. Click "_Actions_" and choose "_Create jobset_". Fill the form with the following values:

- **Identifier**: `hello`
- **Nix expression**: `examples/hello.nix` in `hydra`
- **Check interval**: 60
- **Scheduling shares**: 1

We have to add two inputs for this jobset. One for _nixpkgs_ and one for _hydra_ (which we are referencing in the Nix expression above):

- **Input name**: `nixpkgs`
- **Type**: `Git checkout`
- **Value**: `https://github.com/nixos/nixpkgs-channels nixos-20.03`

- **Input name**: `hydra`
- **Type**: `Git checkout`
- **Value**: `https://github.com/nixos/hydra`

Make sure **State** at the top of the page is set to "_Enabled_" and click on "_Create jobset_". This concludes the creation of a jobset that evaluates [./examples/hello.nix](./examples/hello.nix) once a minute. Clicking "_Evaluations_" should list the first evaluation of the newly created jobset after a brief delay.

## Building And Developing

### Building Hydra

You can build Hydra via `nix-build` using the provided [default.nix](./default.nix):

```
$ nix-build
```

### Development Environment

You can use the provided shell.nix to get a working development environment:
```
$ nix-shell
$ autoreconfPhase
$ configurePhase # NOTE: not ./configure
$ make
```

### Executing Hydra During Development

When working on new features or bug fixes you need to be able to run Hydra from your working copy. This
can be done using [foreman](https://github.com/ddollar/foreman):

```
$ nix-shell
$ # hack hack
$ make
$ foreman start
```

Have a look at the [Procfile](./Procfile) if you want to see how the processes are being started. In order to avoid
conflicts with services that might be running on your host, hydra and postgress are started on custom ports:

- hydra-server: 63333 with the username "alice" and the password "foobar"
- postgresql: 64444

Note that this is only ever meant as an ad-hoc way of executing Hydra during development. Please make use of the
NixOS module for actually running Hydra in production.

### Checking your patches

After making your changes, verify the test suite passes and perlcritic is still happy.

Start by following the steps in [Development Environment](#development-environment).

Then, you can run the tests and the perlcritic linter together with:

```console
$ nix-shell
$ make check
```

You can run a single test with:

```
$ nix-shell
$ yath test ./t/foo/bar.t
```

And you can run just perlcritic with:

```
$ nix-shell
$ make perlcritic
```

### JSON API

You can also interface with Hydra through a JSON API. The API is defined in [hydra-api.yaml](./hydra-api.yaml) and you can test and explore via the [swagger editor](https://editor.swagger.io/?url=https://raw.githubusercontent.com/NixOS/hydra/master/hydra-api.yaml)

## Additional Resources

- [Hydra User's Guide](https://nixos.org/hydra/manual/)
- [Hydra on the NixOS Wiki](https://nixos.wiki/wiki/Hydra)
- [hydra-cli](https://github.com/nlewo/hydra-cli)
- [Peter Simons - Hydra: Setting up your own build farm (NixOS)](https://www.youtube.com/watch?v=RXV0Y5Bn-QQ)

## License
Hydra is licensed under [GPL-3.0](./COPYING)

Icons provided free by [EmojiOne](http://emojione.com).

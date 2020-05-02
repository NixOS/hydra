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
    --email-address '<EMAIL>' --password <PASSWORD> --role admin
```

Afterwards you should be able to log by clicking on "_Sign In_" on the top right of the web interface using the credentials specified by `hydra-crate-user`. Once you are logged in you can click "_Admin -> Create Project_" to configure your first project.

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
$ ./bootstrap
$ configurePhase # NOTE: not ./configure
$ make
```

## Additional Resources

- [Hydra User's Guide](https://nixos.org/hydra/manual/)
- [Hydra on the NixOS Wiki](https://nixos.wiki/wiki/Hydra)
- [hydra-cli](https://github.com/nlewo/hydra-cli)
- [Peter Simons - Hydra: Setting up your own build farm (NixOS)](https://www.youtube.com/watch?v=RXV0Y5Bn-QQ)

## License
Hydra is licensed under [GPL-3.0](./COPYING)

Icons provided free by [EmojiOne](http://emojione.com).

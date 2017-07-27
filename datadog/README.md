# Hydra status timeboard

In order to deploy hydra status dashboard you can:

* create a deployment

```
nixops create -d hydra-status /path/to/hydra/datadog/dd-dashboard.nix
```

* setup the default hostname and api/app keys

```
nixops set-args -d hydra-status --argst appKey <app_key> --argstr apiKey <api_key> --argstr host chef
```

* deploy

```
nixops deploy -d hydra-status
```

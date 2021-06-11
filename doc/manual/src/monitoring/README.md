# Monitoring Hydra

## Webserver

The webserver exposes Prometheus metrics for the webserver itself at `/metrics`.

## Queue Runner

The queue runner's status is exposed at `/queue-runner-status`:

```console
$ curl --header "Accept: application/json" http://localhost:63333/queue-runner-status
... JSON payload ...
```


# Monitoring Hydra

## Webserver

The webserver exposes Prometheus metrics for the webserver itself at `/metrics`.

## Queue Runner

The queue runner's status is exposed at `/queue-runner-status`:

```console
$ curl --header "Accept: application/json" http://localhost:63333/queue-runner-status
... JSON payload ...
```

## Notification Daemon

The `hydra-notify` process can expose Prometheus metrics for plugin execution. See
[hydra-notify's Prometheus service](../configuration.md#hydra-notifys-prometheus-service)
for details on enabling and configuring the exporter.

The notification exporter exposes metrics on a per-plugin, per-event-type basis: execution
durations, frequency, successes, and failures.

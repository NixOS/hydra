# `hydra-notify` and Hydra's Notifications

Hydra uses a notification-based subsystem to implement some features and support plugin development. Notifications are sent to `hydra-notify`, which is responsible for dispatching each notification to each plugin.

Notifications are passed from `hydra-queue-runner` to `hydra-notify` through Postgres's `NOTIFY` and `LISTEN` feature.

## Notification Types

Note that the notification format is subject to change and should not be considered an API. Integrate with `hydra-notify` instead of listening directly.

### `cached_build_finished`

* **Payload:** Exactly two values, tab separated: The ID of the evaluation which contains the finished build, followed by the ID of the finished build.
* **When:** Issued directly after an evaluation completes, when that evaluation includes this finished build.
* **Delivery Semantics:** At most once per evaluation.


### `cached_build_queued`

* **Payload:** Exactly two values, tab separated: The ID of the evaluation which contains the finished build, followed by the ID of the queued build.
* **When:** Issued directly after an evaluation completes, when that evaluation includes this queued build.
* **Delivery Semantics:** At most once per evaluation.

### `build_queued`

* **Payload:** Exactly one value, the ID of the build.
* **When:** Issued after the transaction inserting the build in to the database is committed. One notification is sent per new build.
* **Delivery Semantics:** Ephemeral. `hydra-notify` must be running to react to this event. No record of this event is stored.

### `build_started`

* **Payload:** Exactly one value, the ID of the build.
* **When:** Issued directly before building happens, and only if the derivation's outputs cannot be substituted.
* **Delivery Semantics:** Ephemeral. `hydra-notify` must be running to react to this event. No record of this event is stored.

### `step_finished`

* **Payload:** Three values, tab separated: The ID of the build which the step is part of, the step number, and the path on disk to the log file.
* **When:** Issued directly after a step completes, regardless of success. Is not issued if the step's derivation's outputs can be substituted.
* **Delivery Semantics:** Ephemeral. `hydra-notify` must be running to react to this event. No record of this event is stored.

### `build_finished`

* **Payload:** At least one value, tab separated: The ID of the build which finished, followed by IDs of all of the builds which also depended upon this build.
* **When:** Issued directly after a build completes, regardless of success and substitutability.
* **Delivery Semantics:** At least once.

`hydra-notify` will call `buildFinished` for each plugin in two ways:

* The `builds` table's `notificationspendingsince` column stores when the build finished. On startup, `hydra-notify` will query all builds with a non-null `notificationspendingsince` value and treat each row as a received `build_finished` event.

* Additionally, `hydra-notify` subscribes to `build_finished` events and processes them in real time.

After processing, the row's `notificationspendingsince` column is set to null.

It is possible for subsequent deliveries of the same `build_finished` data to imply different outcomes. For example, if the build fails, is restarted, and then succeeds. In this scenario the `build_finished` events will be delivered at least twice, once for the failure and then once for the success.

## Development Notes

### Re-sending a notification

Notifications can be experimentally re-sent on the command line with `psql`, with `NOTIFY $notificationname, '$payload'`.


# Webhooks

Hydra can be notified by github's webhook to trigger a new evaluation when a
jobset has a github repo in its input.
To set up a github webhook go to `https://github.com/<yourhandle>/<yourrepo>/settings` and in the `Webhooks` tab
click on `Add webhook`.

- In `Payload URL` fill in `https://<your-hydra-domain>/api/push-github`.
- In `Content type` switch to `application/json`.
- The `Secret` field can stay empty.
- For `Which events would you like to trigger this webhook?` keep the default option for events on `Just the push event.`.

Then add the hook with `Add webhook`.

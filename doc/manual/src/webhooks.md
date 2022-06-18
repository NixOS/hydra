# Webhooks

Hydra can be notified by github or gitea with webhooks to trigger a new evaluation when a
jobset has a github repo in its input.

## GitHub

To set up a webhook for a GitHub repository go to `https://github.com/<yourhandle>/<yourrepo>/settings`
and in the `Webhooks` tab click on `Add webhook`.

- In `Payload URL` fill in `https://<your-hydra-domain>/api/push-github`.
- In `Content type` switch to `application/json`.
- The `Secret` field can stay empty.
- For `Which events would you like to trigger this webhook?` keep the default option for events on `Just the push event.`.

Then add the hook with `Add webhook`.

## Gitea

To set up a webhook for a Gitea repository go to the settings of the repository in your Gitea instance
and in the `Webhooks` tab click on `Add Webhook` and choose `Gitea` in the drop down.

- In `Target URL` fill in `https://<your-hydra-domain>/api/push-gitea`.
- Keep HTTP method `POST`, POST Content Type `application/json` and Trigger On `Push Events`.
- Change the branch filter to match the git branch hydra builds.

Then add the hook with `Add webhook`.

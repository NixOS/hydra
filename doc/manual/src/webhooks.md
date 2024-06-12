# Webhooks

## GitHub
Hydra can be notified by GitHub's webhook to trigger a new evaluation when a
jobset has a GitHub repo in its input.

GitHub's webhook can be triggered on [various events](https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads). Hydra recognizes the following events.

 - [`push`](https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads#push): triggers a new evaluation for every jobset that have the GitHub repository as a "Git Checkout" input.
 - [`create`](https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads#create) and [`delete`](https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads#deleta): triggers a new evaluation for every jobset that have the GitHub repository as a "github_refs" input.
 - [`pull_request`](https://docs.github.com/en/developers/webhooks-and-events/webhooks/webhook-events-and-payloads#pull_request): triggers a new evaluation for every jobset that have the GitHub repository as a "githubpulls" input.

### Guide

To set up a GitHub webhook go to `https://github.com/<yourhandle>/<yourrepo>/settings` and in the `Webhooks` tab
click on `Add webhook`.

- In `Payload URL` fill in `https://<your-hydra-domain>/api/webhook-github`.
- In `Content type` switch to `application/json`.
- The `Secret` field can stay empty (see below to configure a secret).
- For `Which events would you like to trigger this webhook?` either keep the default option, or select the ones you are interested in (see above for the supported events).

Then add the hook with `Add webhook`.

### Securing GitHub's webhooks
Secrets for webhooks can be configured by adding `github_webhook` keys in your Hydra configuration.
Each `github_webhook` provides a secret (`secret`, a string) for a certain range of repository name (`repo`, a regex) and repository owner (`owner`, a regex).

For instance below we declare one secret, `foo`, for the repositories whose owner is `someone` or `someother` and is named `somerepo`.

**IMPORTANT**: note that secrets should **never** be included directly in your `hydra.conf`, otherwise they will be exposed in plain text in the store. Instead, use includes [as described here](./configuration.html#including-files).

```xml
<github_webhook>
  owner = (someone|someother)
  repo = somerepo
  secret = foo
</github_webhook>
```


# Webhooks

Hydra can be notified by github or gitea with webhooks to trigger a new evaluation when a
jobset has a github repo in its input.

## Webhook Authentication

Hydra supports webhook signature verification for both GitHub and Gitea using HMAC-SHA256. This ensures that webhook
requests are coming from your configured Git forge and haven't been tampered with.

### Configuring Webhook Authentication

1. **Create webhook configuration**: Generate and store webhook secrets securely:
   ```bash
   # Create directory and generate secrets in one step
   mkdir -p /var/lib/hydra/secrets
   cat > /var/lib/hydra/secrets/webhook-secrets.conf <<EOF
   <github>
     secret = $(openssl rand -hex 32)
   </github>
   <gitea>
     secret = $(openssl rand -hex 32)
   </gitea>
   EOF

   # Set secure permissions
   chmod 0600 /var/lib/hydra/secrets/webhook-secrets.conf
   chown hydra:hydra /var/lib/hydra/secrets/webhook-secrets.conf
   ```

2. **Configure Hydra**: Add the following to your `hydra.conf`:
   ```apache
   <webhooks>
     Include /var/lib/hydra/secrets/webhook-secrets.conf
   </webhooks>
   ```

3. **Configure your Git forge**: View the generated secrets and configure them in GitHub/Gitea:
   ```bash
   grep "secret =" /var/lib/hydra/secrets/webhook-secrets.conf
   ```

### Multiple Secrets Support

Hydra supports configuring multiple secrets for each platform, which is useful for:
- Zero-downtime secret rotation
- Supporting multiple environments (production/staging)
- Gradual migration of webhooks

To configure multiple secrets, use array syntax:
```apache
<github>
  secret = current-webhook-secret
  secret = previous-webhook-secret
</github>
```

## GitHub

To set up a webhook for a GitHub repository go to `https://github.com/<yourhandle>/<yourrepo>/settings`
and in the `Webhooks` tab click on `Add webhook`.

- In `Payload URL` fill in `https://<your-hydra-domain>/api/push-github`.
- In `Content type` switch to `application/json`.
- In the `Secret` field, enter the content of your GitHub webhook secret file (if authentication is configured).
- For `Which events would you like to trigger this webhook?` keep the default option for events on `Just the push event.`.

Then add the hook with `Add webhook`.

### Verifying GitHub Webhook Security

After configuration, GitHub will send webhook requests with an `X-Hub-Signature-256` header containing the HMAC-SHA256
signature of the request body. Hydra will verify this signature matches the configured secret.

## Gitea

To set up a webhook for a Gitea repository go to the settings of the repository in your Gitea instance
and in the `Webhooks` tab click on `Add Webhook` and choose `Gitea` in the drop down.

- In `Target URL` fill in `https://<your-hydra-domain>/api/push-gitea`.
- Keep HTTP method `POST`, POST Content Type `application/json` and Trigger On `Push Events`.
- In the `Secret` field, enter the content of your Gitea webhook secret file (if authentication is configured).
- Change the branch filter to match the git branch hydra builds.

Then add the hook with `Add webhook`.

### Verifying Gitea Webhook Security

After configuration, Gitea will send webhook requests with an `X-Gitea-Signature` header containing the HMAC-SHA256
signature of the request body. Hydra will verify this signature matches the configured secret.

## Troubleshooting

If you receive 401 Unauthorized errors:
- Verify the webhook secret in your Git forge matches the content of the secret file exactly
- Check that the secret file has proper permissions (should be 0600)
- Look at Hydra's logs for specific error messages
- Ensure the correct signature header is being sent by your Git forge

If you see warnings about webhook authentication not being configured:
- Configure webhook authentication as described above to secure your endpoints

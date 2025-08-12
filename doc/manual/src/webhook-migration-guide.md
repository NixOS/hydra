# Webhook Authentication Migration Guide

This guide helps Hydra administrators migrate from unauthenticated webhooks to authenticated webhooks to secure their Hydra instances against unauthorized job evaluations.

## Why Migrate?

Currently, Hydra's webhook endpoints (`/api/push-github` and `/api/push-gitea`) accept any POST request without authentication. This vulnerability allows:
- Anyone to trigger expensive job evaluations
- Potential denial of service through repeated requests
- Manipulation of build timing and scheduling

## Step-by-Step Migration for NixOS

### 1. Create Webhook Configuration

Create a webhook secrets configuration file with the generated secrets:

```bash
# Create the secrets configuration file with inline secret generation
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
chown hydra-www:hydra /var/lib/hydra/secrets/webhook-secrets.conf
```

**Important**: Save the generated secrets to configure them in GitHub/Gitea later. You can view them with:
```bash
cat /var/lib/hydra/secrets/webhook-secrets.conf
```

Then update your NixOS configuration to include the webhook configuration:

```nix
{
  services.hydra-dev = {
    enable = true;
    hydraURL = "https://hydra.example.com";
    notificationSender = "hydra@example.com";

    extraConfig = ''
      <webhooks>
        Include /var/lib/hydra/secrets/webhook-secrets.conf
      </webhooks>
    '';
  };
}
```

For multiple secrets (useful for rotation or multiple environments), update your webhook-secrets.conf:

```apache
<github>
  secret = your-github-webhook-secret-prod
  secret = your-github-webhook-secret-staging
</github>
<gitea>
  secret = your-gitea-webhook-secret
</gitea>
```

### 2. Deploy Configuration

Apply the NixOS configuration:

```bash
nixos-rebuild switch
```

This will automatically restart Hydra services with the new configuration.

### 3. Verify Configuration

Check Hydra's logs to ensure secrets were loaded successfully:

```bash
journalctl -u hydra-server | grep -i webhook
```

You should not see warnings about webhook authentication not being configured.

### 4. Update Your Webhooks

#### GitHub
1. Navigate to your repository settings: `https://github.com/<owner>/<repo>/settings/hooks`
2. Edit your existing Hydra webhook
3. In the "Secret" field, paste the content of `/var/lib/hydra/secrets/github-webhook-secret`
4. Click "Update webhook"
5. GitHub will send a ping event to verify the configuration

#### Gitea
1. Navigate to your repository webhook settings
2. Edit your existing Hydra webhook
3. In the "Secret" field, paste the content of `/var/lib/hydra/secrets/gitea-webhook-secret`
4. Click "Update Webhook"
5. Use the "Test Delivery" button to verify the configuration

### 5. Test the Configuration

After updating each webhook:
1. Make a test commit to trigger the webhook
2. Check Hydra's logs for successful authentication
3. Verify the evaluation was triggered in Hydra's web interface

## Troubleshooting

### 401 Unauthorized Errors

If webhooks start failing with 401 errors:
- Verify the secret in the Git forge matches the file content exactly
- Check file permissions: `ls -la /var/lib/hydra/secrets/`
- Ensure no extra whitespace in secret files
- Check Hydra logs for specific error messages

### Webhook Still Unauthenticated

If you see warnings about unauthenticated webhooks after configuration:
- Verify the configuration syntax in your NixOS module
- Ensure the NixOS configuration was successfully applied
- Check that the webhook-secrets.conf file exists and is readable by the Hydra user
- Verify the Include path is correct in your hydra.conf
- Check the syntax of your webhook-secrets.conf file

### Testing Without Git Forge

You can test webhook authentication using curl:

```bash
# Read the secret
SECRET=$(cat /var/lib/hydra/secrets/github-webhook-secret)

# Create test payload
PAYLOAD='{"ref":"refs/heads/main","repository":{"clone_url":"https://github.com/test/repo.git"}}'

# Calculate signature
SIGNATURE="sha256=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)"

# Send authenticated request
curl -X POST https://your-hydra/api/push-github \
  -H "Content-Type: application/json" \
  -H "X-Hub-Signature-256: $SIGNATURE" \
  -d "$PAYLOAD"
```

For Gitea (no prefix in signature):
```bash
# Read the secret
SECRET=$(cat /var/lib/hydra/secrets/gitea-webhook-secret)

# Create test payload
PAYLOAD='{"ref":"refs/heads/main","repository":{"clone_url":"https://gitea.example.com/test/repo.git"}}'

# Calculate signature
SIGNATURE=$(echo -n "$PAYLOAD" | openssl dgst -sha256 -hmac "$SECRET" | cut -d' ' -f2)

# Send authenticated request
curl -X POST https://your-hydra/api/push-gitea \
  -H "Content-Type: application/json" \
  -H "X-Gitea-Signature: $SIGNATURE" \
  -d "$PAYLOAD"
```

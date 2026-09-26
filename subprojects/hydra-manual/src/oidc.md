# Single sign-on with OIDC

Hydra can delegate login to one or more OpenID Connect providers, alongside the built-in accounts and
LDAP or instead of them.
Each provider gets a *"Sign in with &lt;display name&gt;"* entry in the sign-in menu,
or a plain **Sign in** button when a provider is the only way to sign in.
To make it the only way, set `local_auth_enabled = 0` in `hydra.conf` as well; see
[Turning off Hydra's own user management](configuration.md#turning-off-hydras-own-user-management).

## How a login works

Hydra runs the OIDC Authorization Code flow with PKCE (S256), `state` and `nonce`.
It requests the scopes `openid profile email` plus `extra_scopes`.
The login has to finish within 10 minutes.

Hydra validates the ID token's signature against the provider's JWKS, and checks `iss`, `aud`
(your `client_id`), `exp`, `nbf` and `nonce`.
An unknown key ID triggers one JWKS refetch, so key rotation needs no restart.

Hydra logs the user in as `<provider>:<sub>`, with the `email` and `name` claims from the ID token.
Hydra updates both on every login, so changes at the provider carry over.
Hydra's pages show OIDC users by their email address, since `sub` is often an opaque ID.
Hydra needs a usable `email` claim in the ID token and does not call the userinfo endpoint.
If the token has `email_verified: false`, Hydra refuses the login.
If `allowed_domains` is set, the address must be in one of those domains.
OIDC users have no password, so they can only sign in through their provider.

## Configuring a provider

Each provider is a `<provider>` block inside `<oidc>` in `hydra.conf`.
The block name appears in the URLs and in usernames, so pick something stable.

```apache
<oidc>
  <provider authentik>
    display_name = "Authentik"
    discovery_url = "https://authentik.example.com/application/o/hydra/.well-known/openid-configuration"
    client_id = "hydra"
    client_secret_file = "/var/lib/hydra/secrets/authentik-client-secret"
  </provider>
</oidc>
```

Register `https://<hydra>/oidc-callback/<provider>` as the redirect URI at the IdP.

| Setting | Meaning |
| --- | --- |
| `display_name` | Text of the menu entry. Defaults to `OIDC (<name>)`. |
| `discovery_url` | The provider's `.well-known/openid-configuration`. |
| `authorization_endpoint`, `token_endpoint`, `jwks_uri`, `issuer` | Required if there is no `discovery_url`. |
| `client_id` | Required. |
| `client_secret` | The client secret. |
| `client_secret_file` | File containing only the client secret, used instead of `client_secret`. |
| `ca_file` | CA bundle for verifying the provider's TLS certificate. |
| `extra_scopes` | Space-separated scopes to request in addition to `openid profile email`. |
| `end_session_endpoint` | Where to send the browser on sign-out. Overrides the discovery document. |
| `role_claim` | Claim to read roles from. Defaults to `hydra_roles`. |
| `role_mapping` | Translates claim values into Hydra roles, see [Roles](#roles). |

Hydra checks the configuration and reads `client_secret_file` at startup, so a new secret needs a
restart.
It fetches the discovery document on the first login, so Hydra starts even when the IdP is down.
Hydra keeps the discovered endpoints until it restarts.
Hydra caches the JWKS for a minute.

You can configure several providers.
Each has its own role settings, and its users are separate Hydra users.

## Roles

Hydra reads roles from the `role_claim` in the ID token and replaces the user's roles with them on
every login, including roles an admin set in Hydra.
If the token has no role claim at all, Hydra leaves the user's roles unchanged, so you can manage
them in Hydra instead.
The claim has to be in the ID token. Hydra ignores claims only available from the userinfo endpoint.

`role_mapping` translates the IdP's values into Hydra roles.
Hydra's roles are `admin`, `bump-to-front`, `cancel-build`, `create-projects`, `eval-jobset` and
`restart-jobs`.
Repeat a key to grant several roles.
Keys are case-sensitive, and values that are not keys grant nothing.

```apache
<provider authentik>
  # ...
  role_claim = "groups"
  <role_mapping>
    hydra-admins = admin
    hydra-builders = create-projects
    hydra-builders = eval-jobset
    hydra-operators = restart-jobs
  </role_mapping>
</provider>
```

Without a `role_mapping`, the claim must contain Hydra role names, and Hydra drops unknown values.
Some IdPs, like kanidm, disallow dashes in claim values, so Hydra also accepts underscores, as in
`restart_jobs`.

Getting the claim into the ID token depends on the IdP:

* **Keycloak.** Add a protocol mapper to the client, such as the built-in `groups` mapper with
  *Add to ID token* enabled.
* **kanidm.** Use `kanidm system oauth2 update-claim-map hydra hydra_roles hydra_admins admin`.
* **Authentik.** See the [example](#authentik) below.

## Sign-out

Signing out clears Hydra's session.
If the provider has an `end_session_endpoint`, Hydra also redirects there with `client_id` and
`post_logout_redirect_uri`, which signs the user out of the IdP.
kanidm and some other IdPs don't offer one, so users stay signed in there.

## Examples

### Authentik

1. In Authentik, create a provider: *Applications* → *Providers* → *Create* → *OAuth2/OpenID
   Connect*.
   * Client type: *Confidential*
   * Redirect URI: `https://hydra.example.com/oidc-callback/authentik`, where `authentik` is the
     name of the `<provider>` block. It has to match exactly, including the scheme and any path
     prefix Hydra is served under.
1. Create an application that uses that provider.
1. Add the *authentik default OAuth Mapping: OpenID 'groups'* scope mapping to the provider.
1. Write the client secret, and nothing else, to `/var/lib/hydra/secrets/authentik-client-secret`.
1. In Hydra:

   ```apache
   <oidc>
     <provider authentik>
       display_name = "Authentik"
       discovery_url = "https://authentik.example.com/application/o/hydra/.well-known/openid-configuration"
       client_id = "the-client-id-from-authentik"
       client_secret_file = "/var/lib/hydra/secrets/authentik-client-secret"
       # Only needed if the provider does not include `groups` by default.
       extra_scopes = "groups"
       role_claim = "groups"
       <role_mapping>
         hydra-admins = admin
         hydra-builders = create-projects
         hydra-builders = eval-jobset
         hydra-operators = restart-jobs
         hydra-operators = cancel-build
         hydra-operators = bump-to-front
       </role_mapping>
     </provider>
   </oidc>
   ```

The `groups` claim contains every group the user is in, so give the Hydra groups names that won't
collide with your other Authentik groups.

To avoid depending on group names, write a scope mapping that emits Hydra role names directly, and
leave `role_claim` at its default:

```python
{
    "hydra_roles": [
        role
        for group, role in [("Hydra Admins", "admin"), ("Hydra Operators", "restart-jobs")]
        if group in user.ak_groups
    ]
}
```

### GitHub

GitHub's OAuth Apps don't issue ID tokens, so Hydra can't use GitHub directly as an OIDC provider.
Put a broker in front of it instead. With Authentik:

1. Create a GitHub OAuth app: *Settings* → *Developer settings* → *OAuth Apps* → *New OAuth App*.
   * Homepage URL: `https://authentik.example.com/`
   * Authorization callback URL: `https://authentik.example.com/source/oauth/github/callback/`
1. In Authentik, create a GitHub source: *Sources* → *Create* → *Social Source* → *GitHub*. Paste
   the client ID and secret, and request the `user:email` scope.
1. Assign the source to a stage, so that users can enroll through it.
1. Set up the Authentik provider and Hydra as in the [Authentik example](#authentik).

Users need a primary email address on their GitHub account, or they can't sign in.
The broker sets `sub`, which is part of the Hydra username. For a GitHub source, `sub` is the
numeric GitHub user ID. Switching brokers changes usernames, so Hydra treats returning users as new ones.

Hydra also has an older, non-OIDC GitHub login, configured with `github_client_id` and
`github_client_secret`.
It grants no roles.

For a working setup, see the kanidm provider in `subprojects/hydra-tests/Hydra/Controller/User/oidc.t`
and `foreman/start-kanidm.pl`.

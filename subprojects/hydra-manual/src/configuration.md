Configuration
=============

This chapter is a collection of configuration snippets for different scenarios.

Hydra reads its configuration in either of two formats, chosen by the file's
extension:

- `hydra.conf` --- the Apache-style syntax Hydra has always used, parsed by
  `Config::General`, which has [a pretty thorough documentation on their file
  format](https://metacpan.org/pod/Config::General#CONFIG-FILE-FORMAT).
  Hydra calls that parser with the following options:
  - `-UseApacheInclude => 1`
  - `-IncludeAgain => 1`
  - `-IncludeRelative => 1`

- `hydra.json` --- the same settings written as JSON.
  A repeated block in the Apache-style syntax is a JSON array, and a single block is a JSON object.
  The two formats produce the same configuration, so nothing behaves differently depending on which you choose.

`HYDRA_CONFIG` names the file to read.
Without it Hydra looks for `hydra.json` and then `hydra.conf` in its state directory.

Whichever you use, `hydra-config` reads the configuration and prints it as JSON, exiting non-zero if it cannot be parsed.
It is the way to check a file before restarting anything:

```console
$ hydra-config /var/lib/hydra/hydra.json
$ hydra-config | jq -r '.compress_build_logs_compression // ""'
zstd
```

Because the output is JSON whichever format the input was, `jq` is how a script reads one setting without knowing how the file is written.
Given several files it folds them together the way `includes` does, so a whole deployment's configuration can be checked at once.

It also refuses any configuration that keeps a secret where anyone can read it:

```console
$ hydra-config /var/lib/hydra/hydra.json
hydra-config: /var/lib/hydra/hydra.json is world-readable and sets `github_authorization'.
```

See [Including files](#including-files) below for where those settings belong instead.

`hydra-config` also makes sure that world-readable settings files do not contain secrets, in support of the idiom described in the next section.

Including files
---------------

Secrets must not go in your main configuration file.
This is **IMPORTANT** because that is how you keep your **secrets** out of the **Nix store**.
Hopefully this got your attention 😌

This:
```apache
<github_authorization>
NixOS = Bearer gha-secret😱secret😱secret😱
</github_authorization>
```
should **NOT** be in `hydra.conf`.

And likewise,
```json
{
  "github_authorization": {
    "NixOS": "Bearer gha-secret😱secret😱secret😱"
  }
}
```
should **NOT** be in `hydra.json`.

`hydra.conf` is rendered in the Nix store and is therefore world-readable.

Instead, the above should be written to a file outside the Nix store by other means (manually, using Nixops' secrets feature, etc) and read from there.
Both formats can do that, by different means.

`hydra.conf` uses `Config::General`'s Apache-style directive:
```apache
Include /run/keys/hydra/github_authorizations.conf
```

For JSON configuration files, we allow wrapping the entire settings object, naming the files to be read alongside them:
```json
{
  "includes": [ "/run/keys/hydra/github_authorizations.conf" ],
  "settings": { "max_servers": 25 }
}
```

The wrapper is optional and must hold nothing but those two keys; a JSON file without a `settings` key is read exactly as it always was.
An included file is settings, in whichever format its own extension names, which is why the example above can read its secrets from an Apache-style file.
A JSON one may wrap in turn.

Blocks combine and repeated blocks append, so a file holding only the secret part of a block adds to what the main file says about it rather than replacing it.
A single setting given in two files is an error rather than one of them quietly winning.

`hydra-config` knows which settings hold a secret and will tell you if one of them is in a file anyone can read, which is the mistake this section exists to prevent.
Run it after changing your configuration and before restarting anything.

NixOS module
------------

The NixOS module writes `hydra.json` from the structured `services.hydra-dev.settings` option, and does not generate the Apache-style syntax at all.
Anything it writes is world-readable in the Nix store, so secrets go in `services.hydra-dev.includes`, which names files deployed by other means.

The NixOS module validates the final configuration using `hydra-config`, so you don't need to start hydra in order to see if your configuration is valid.
Since the NixOS module will only populate files in the Nix store, this is also very useful to make sure your NixOS configuration doesn't accidentally include secrets.

Serving behind reverse proxy
----------------------------

To serve hydra web server behind reverse proxy like *nginx* or *httpd* some additional configuration must be made.

Edit your `hydra.conf` file in a similar way to this example:

```conf
using_frontend_proxy 1
base_uri example.com
```

`base_uri` should be your hydra servers proxied URL.
If you are using Hydra nixos module then setting `hydraURL` option should be enough.

You also need to configure your reverse proxy to pass `X-Request-Base` to hydra, with the same value as `base_uri`.
This also covers the case of serving Hydra with a prefix path, as in [http://example.com/hydra]().

For example if you are using nginx, then use configuration similar to following:

    server {
        listen 433 ssl;
        server_name example.com;
        .. other configuration ..
        location /hydra/ {

            proxy_pass http://127.0.0.1:3000/;

            proxy_set_header  Host              $host;
            proxy_set_header  X-Real-IP         $remote_addr;
            proxy_set_header  X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header  X-Forwarded-Proto $scheme;
            proxy_set_header  X-Request-Base    /hydra;
        }
    }

Note the trailing slash on the `proxy_pass` directive, which causes nginx to strip off the `/hydra/` part of the URL before passing it to hydra.

Populating a Cache
------------------

A common use for Hydra is to pre-build and cache derivations which take a long time to build.
While it is possible to direcly access the Hydra server's store over SSH, a more scalable option is to upload built derivations to a remote store like an [S3-compatible object store](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-help-stores.html#s3-binary-cache-store).
Setting the `store_uri` parameter will cause Hydra to sign and upload derivations as they are built:

```
store_uri = s3://cache-bucket-name?compression=zstd&parallel-compression=true&write-nar-listing=1&ls-compression=br&log-compression=br&secret-key=/path/to/cache/private/key
```

This example uses [Zstandard](https://github.com/facebook/zstd) compression on derivations to reduce CPU usage on the server, but [Brotli](https://brotli.org/) compression for derivation listings and build logs because it has better browser support.

See [`nix help stores`](https://nixos.org/manual/nix/stable/command-ref/new-cli/nix3-help-stores.html) for a description of the store URI format.

Statsd Configuration
--------------------

By default, Hydra will send stats to statsd at `localhost:8125`.
Point Hydra to a different server via:

```
<statsd>
  host = alternative.host
  port = 18125
</statsd>
```

hydra-notify's Prometheus service
---------------------------------

hydra-notify supports running a Prometheus webserver for metrics.
The exporter does not run unless a listen address and port are specified in the hydra configuration file, as below:

```conf
<hydra_notify>
  <prometheus>
    listen_address = 127.0.0.1
    port = 9199
  </prometheus>
</hydra_notify>
```

hydra-queue-runner's Prometheus service
---------------------------------------

hydra-queue-runner supports running a Prometheus webserver for metrics.
The exporter's address defaults to exposing on `127.0.0.1:9198`, but is also configurable through the hydra configuration file and a command line argument, as below.
A port of `:0` will make the exposer choose a random, available port.

```conf
queue_runner_metrics_address = 127.0.0.1:9198
# or
queue_runner_metrics_address = [::]:9198
```

```shell
$ hydra-queue-runner --prometheus-address 127.0.0.1:9198
# or
$ hydra-queue-runner --prometheus-address [::]:9198
```

Overflow binary cache (optional)
--------------------------------

The queue runner can upload builds of selected jobsets to a separate "overflow"
S3 bucket, for example to keep large staging rebuilds out of the main cache.
A step is uploaded to the overflow bucket only when every jobset referencing it
is listed. Shared steps go to the default bucket.

Both buckets must live on the same S3
endpoint and use static credentials: when a later build from a regular jobset
needs outputs that only exist in the overflow bucket, the queue runner copies
them back to the default bucket server-side instead of rebuilding.

Configured in `queue-runner.toml`:

```toml
[overflowStore]
store = "s3://hydra-overflow?region=eu-west-1"
jobsets = ["nixpkgs:staging-next"]
```

Using LDAP as authentication backend (optional)
-----------------------------------------------

Instead of using Hydra's built-in user management you can optionally use LDAP to manage roles and users.

This is configured by defining the `<ldap>` block in the configuration file.
In this block it's possible to configure the authentication plugin in the `<config>` block.
All options are directly passed to `Catalyst::Authentication::Store::LDAP`.
The documentation for the available settings can be found [here](https://metacpan.org/pod/Catalyst::Authentication::Store::LDAP#CONFIGURATION-OPTIONS).

Note that the bind password (if needed) should be supplied as an included file to prevent it from leaking to the Nix store.

Roles can be assigned to users based on their LDAP group membership.
For this to work `use_roles = 1` needs to be defined for the authentication plugin.
LDAP groups can then be mapped to Hydra roles using the `<role_mapping>` block.

Example configuration:
```
<ldap>
  <config>
    <credential>
      class = Password
      password_field = password
      password_type = self_check
    </credential>
    <store>
      class = LDAP
      ldap_server = localhost
      <ldap_server_options>
        timeout = 30
      </ldap_server_options>
      binddn = "cn=root,dc=example"
      include ldap-password.conf
      start_tls = 0
      <start_tls_options>
        verify = none
      </start_tls_options>
      user_basedn = "ou=users,dc=example"
      user_filter = "(&(objectClass=inetOrgPerson)(cn=%s))"
      user_scope = one
      user_field = cn
      <user_search_options>
        deref = always
      </user_search_options>
      # Important for role mappings to work:
      use_roles = 1
      role_basedn = "ou=groups,dc=example"
      role_filter = "(&(objectClass=groupOfNames)(member=%s))"
      role_scope = one
      role_field = cn
      role_value = dn
      <role_search_options>
        deref = always
      </role_search_options>
    </store>
  </config>
  <role_mapping>
    # Make all users in the hydra_admin group Hydra admins
    hydra_admin = admin
    # Allow all users in the dev group to eval jobsets, restart jobs and cancel builds
    dev = eval-jobset
    dev = restart-jobs
    dev = cancel-build
  </role_mapping>
</ldap>
```

Then, place the password to your LDAP server in `/var/lib/hydra/ldap-password.conf`:

```
bindpw = the-ldap-password
```

### Debugging LDAP

Set the `debug` parameter under `ldap.config.ldap_server_options.debug`:

```
<ldap>
  <config>
    <store>
      <ldap_server_options>
        debug = 2
      </ldap_server_options>
    </store>
  </config>
</ldap>
```

### Legacy LDAP Configuration

Hydra used to load the LDAP configuration from a YAML file in the `HYDRA_LDAP_CONFIG` environment variable.
This behavior is deperecated and will be removed.

When Hydra uses the deprecated YAML file, Hydra applies the following default role mapping:

```
<ldap>
  <role_mapping>
    hydra_admin = admin
    hydra_bump-to-front = bump-to-front
    hydra_cancel-build = cancel-build
    hydra_create-projects = create-projects
    hydra_restart-jobs = restart-jobs
  </role_mapping>
</ldap>
```

Note that configuring both the LDAP parameters in the hydra.conf and via the environment variable is a fatal error.

Webhook Authentication
---------------------

Hydra supports authenticating webhook requests from GitHub and Gitea to prevent unauthorized job evaluations.
Webhook secrets should be stored in separate files outside the Nix store for security using Config::General's include mechanism.

In your main `hydra.conf`:
```apache
<webhooks>
  Include /var/lib/hydra/secrets/webhook-secrets.conf
</webhooks>
```

Then create `/var/lib/hydra/secrets/webhook-secrets.conf` with your actual secrets:
```apache
<github>
  secret = your-github-webhook-secret
</github>
<gitea>
  secret = your-gitea-webhook-secret
</gitea>
```

For multiple secrets (useful for rotation or multiple environments), use an array:
```apache
<github>
  secret = your-github-webhook-secret-prod
  secret = your-github-webhook-secret-staging
</github>
```

**Important**: The secrets file should have restricted permissions (e.g., 0600) to prevent unauthorized access.
See the [Webhooks documentation](webhooks.md) for detailed setup instructions.

Embedding Extra HTML
--------------------

Embed an analytics widget or other HTML in the `<head>` of each HTML document via:

```conf
tracker = <script src="...">
```

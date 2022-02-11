Configuration
=============

This chapter is a collection of configuration snippets for different
scenarios.

The configuration is parsed by `Config::General` which has [a pretty
thorough documentation on their file format](https://metacpan.org/pod/Config::General#CONFIG-FILE-FORMAT).
Hydra calls the parser with the following options:
- `-UseApacheInclude => 1`
- `-IncludeAgain => 1`
- `-IncludeRelative => 1`

Including files
---------------

`hydra.conf` supports Apache-style includes. This is **IMPORTANT**
because that is how you keep your **secrets** out of the **Nix store**.
Hopefully this got your attention 😌

This:
```
<github_authorization>
NixOS = Bearer gha-secret😱secret😱secret😱
</github_authorization>
```
should **NOT** be in `hydra.conf`.

`hydra.conf` is rendered in the Nix store and is therefore world-readable.

Instead, the above should be written to a file outside the Nix store by
other means (manually, using Nixops' secrets feature, etc) and included
like so:
```
Include /run/keys/hydra/github_authorizations.conf
```

Serving behind reverse proxy
----------------------------

To serve hydra web server behind reverse proxy like *nginx* or *httpd*
some additional configuration must be made.

Edit your `hydra.conf` file in a similar way to this example:

```conf
using_frontend_proxy 1
base_uri example.com
```

`base_uri` should be your hydra servers proxied URL. If you are using
Hydra nixos module then setting `hydraURL` option should be enough.

If you want to serve Hydra with a prefix path, for example
[http://example.com/hydra]() then you need to configure your reverse
proxy to pass `X-Request-Base` to hydra, with prefix path as value. For
example if you are using nginx, then use configuration similar to
following:

    server {
        listen 433 ssl;
        server_name example.com;
        .. other configuration ..
        location /hydra/ {

            proxy_pass     http://127.0.0.1:3000;
            proxy_redirect http://127.0.0.1:3000 https://example.com/hydra;

            proxy_set_header  Host              $host;
            proxy_set_header  X-Real-IP         $remote_addr;
            proxy_set_header  X-Forwarded-For   $proxy_add_x_forwarded_for;
            proxy_set_header  X-Forwarded-Proto $scheme;
            proxy_set_header  X-Request-Base    /hydra;
        }
    }

Statsd Configuration
--------------------

By default, Hydra will send stats to statsd at `localhost:8125`. Point Hydra to a different server via:

```
<statsd>
  host = alternative.host
  port = 18125
</statsd>
```

hydra-notify's Prometheus service
---------------------------------

hydra-notify supports running a Prometheus webserver for metrics. The
exporter does not run unless a listen address and port are specified
in the hydra configuration file, as below:

```conf
<hydra_notify>
  <prometheus>
    listen_address = 127.0.0.1
    port = 9199
  </prometheus>
</hydra_notify>
```

Using LDAP as authentication backend (optional)
-----------------------------------------------

Instead of using Hydra's built-in user management you can optionally
use LDAP to manage roles and users.

This is configured by defining the `<ldap>` block in the configuration file.
In this block it's possible to configure the authentication plugin in the
`<config>` block. All options are directly passed to `Catalyst::Authentication::Store::LDAP`.
The documentation for the available settings can be found [here]
(https://metacpan.org/pod/Catalyst::Authentication::Store::LDAP#CONFIGURATION-OPTIONS).

Note that the bind password (if needed) should be supplied as an included file to
prevent it from leaking to the Nix store.

Roles can be assigned to users based on their LDAP group membership. For this
to work *use\_roles = 1* needs to be defined for the authentication plugin.
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
  </config>
  <role_mapping>
    # Make all users in the hydra_admin group Hydra admins
    hydra_admin = admin
    # Allow all users in the dev group to restart jobs and cancel builds
    dev = restart-jobs
    dev = cancel-builds
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

Hydra used to load the LDAP configuration from a YAML file in the
`HYDRA_LDAP_CONFIG` environment variable. This behavior is deperecated
and will be removed.

When Hydra uses the deprecated YAML file, Hydra applies the following
default role mapping:

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

Note that configuring both the LDAP parameters in the hydra.conf and via
the environment variable is a fatal error.

Embedding Extra HTML
--------------------

Embed an analytics widget or other HTML in the `<head>` of each HTML document via:

```conf
tracker = <script src="...">
```

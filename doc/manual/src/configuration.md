Configuration
=============

This chapter is a collection of configuration snippets for different
scenarios.

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
Include github_authorizations.conf
```

Note that the included files must be relative to `hydra.conf` (not absolute).

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

Using LDAP as authentication backend (optional)
-----------------------------------------------

Instead of using Hydra\'s built-in user management you can optionally
use LDAP to manage roles and users.

The `hydra-server` accepts the environment variable
*HYDRA\_LDAP\_CONFIG*. The value of the variable should point to a valid
YAML file containing the Catalyst LDAP configuration. The format of the
configuration file is describe in the
[*Catalyst::Authentication::Store::LDAP*
documentation](https://metacpan.org/pod/Catalyst::Authentication::Store::LDAP#CONFIGURATION-OPTIONS).
An example is given below.

Roles can be assigned to users based on their LDAP group membership
(*use\_roles: 1* in the below example). For a user to have the role
*admin* assigned to them they should be in the group *hydra\_admin*. In
general any LDAP group of the form *hydra\_some\_role* (notice the
*hydra\_* prefix) will work.

    credential:
      class: Password
      password_field: password
      password_type: self_check
    store:
      class: LDAP
      ldap_server: localhost
      ldap_server_options.timeout: 30
      binddn: "cn=root,dc=example"
      bindpw: notapassword
      start_tls: 0
      start_tls_options
        verify:  none
      user_basedn: "ou=users,dc=example"
      user_filter: "(&(objectClass=inetOrgPerson)(cn=%s))"
      user_scope: one
      user_field: cn
      user_search_options:
        deref: always
      use_roles: 1
      role_basedn: "ou=groups,dc=example"
      role_filter: "(&(objectClass=groupOfNames)(member=%s))"
      role_scope: one
      role_field: cn
      role_value: dn
      role_search_options:
        deref: always

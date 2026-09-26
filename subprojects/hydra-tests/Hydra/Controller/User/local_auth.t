use strict;
use warnings;
use Setup;
use Test2::V0;
use HTTP::Request::Common;

# `local_auth_enabled = 0` takes Hydra's own accounts out of the sign-in menu,
# and when that leaves one way to sign in the menu becomes a Sign in button that
# goes straight there. The endpoint behind the form goes away with it: an offer
# to sign in that does not work is worse than no offer.

my $ctx = test_context(hydra_config => <<'CFG');
    local_auth_enabled = 0
    <oidc>
        <provider authentik>
            display_name = "Authentik"
            authorization_endpoint = "https://authentik.example.com/authorize"
            token_endpoint = "https://authentik.example.com/token"
            jwks_uri = "https://authentik.example.com/certs"
            issuer = "https://authentik.example.com"
            client_id = "hydra"
            client_secret = "hunter2"
        </provider>
    </oidc>
CFG
setup_catalyst_test($ctx);

# A local account that exists and has the right password, and still cannot get
# in, which is the point of the setting.
my $user = $ctx->db->resultset('Users')->create({
    username => 'alice',
    emailaddress => 'alice@example.com',
    password => '!'
});
$user->setPassword('foobar');

subtest "a single provider gets a button, not a menu" => sub {
    my $response = request(GET '/');
    ok($response->is_success, "the page renders");
    my $content = $response->content;

    unlike($content, qr{id="sign-in-menu"}, "no dropdown to choose from");
    like($content, qr{<a class="nav-link" href="/oidc-redirect/authentik\?after=[^"]*">Sign in</a>},
        "a Sign in button going straight to the provider");
    unlike($content, qr{Sign in with a Hydra account}, "nothing left of the password form");
    unlike($content, qr{id="hydra-signin"}, "and no dialog behind it");
};

subtest "the password form is refused at the endpoint too" => sub {
    my $response = request(POST '/login',
        Referer => 'http://localhost/',
        Content => { username => 'alice', password => 'foobar' },
    );
    is($response->code, 403, "even with the right password");
};

subtest "the password form alone also gets a button" => sub {
    my $config = Hydra->config;
    local $config->{oidc} = {};
    local $config->{local_auth_enabled} = "1";

    my $content = request(GET '/')->content;
    unlike($content, qr{id="sign-in-menu"}, "no dropdown to choose from");
    like($content, qr{<a class="nav-link" href="#hydra-signin" data-toggle="modal">Sign in</a>},
        "a Sign in button opening the password dialog");
    like($content, qr{id="hydra-signin"}, "and the dialog is on the page");
};

subtest "no way to sign in at all leaves no sign-in UI" => sub {
    my $config = Hydra->config;
    local $config->{oidc} = {};

    my $content = request(GET '/')->content;
    unlike($content, qr{id="sign-in-menu"}, "no dropdown");
    unlike($content, qr{id="hydra-signin"}, "no dialog");
    unlike($content, qr{>Sign in<}, "and no button pretending otherwise");
};

subtest "two or more ways to sign in get the menu back" => sub {
    my $config = Hydra->config;
    local $config->{local_auth_enabled} = "1";

    my $content = request(GET '/')->content;
    like($content, qr{id="sign-in-menu"}, "the dropdown is back");
    like($content, qr{Sign in with Authentik}, "the provider is in it");
    like($content, qr{Sign in with a Hydra account}, "and so is the password form");
    like($content, qr{id="hydra-signin"}, "with its dialog on the page");
    like($content,
        qr{/oidc-redirect/authentik[^"]*">Sign in with Authentik</a>\s*<div class="dropdown-divider"></div>\s*<a class="dropdown-item" href="#hydra-signin"},
        "with a divider between the provider and the form");
    unlike($content, qr{<div class="dropdown-divider"></div>\s*</div>},
        "and no divider with nothing after it");
};

subtest "and the endpoint works again with it" => sub {
    my $config = Hydra->config;
    local $config->{local_auth_enabled} = "1";

    my $response = request(POST '/login',
        Referer => 'http://localhost/',
        Content => { username => 'alice', password => 'foobar' },
    );
    is($response->code, 302, "the login redirects, as it always did");
};

subtest "a private Hydra can still start an OIDC login" => sub {
    my $config = Hydra->config;
    local $config->{private} = "1";

    # Both legs of the OIDC login arrive with nobody signed in, so neither may
    # be one of the pages that demands a login first. This Hydra has no other
    # way in.
    my $response = request(GET '/oidc-redirect/authentik');
    isnt($response->code, 403, "the redirect to the IdP is not refused");
    like($response->header("Location"), qr{^https://authentik\.example\.com/authorize},
        "it goes to the IdP");

    my $unconfigured = request(GET '/oidc-callback/nosuchprovider');
    isnt($unconfigured->code, 403, "the callback is not refused either");
    is($unconfigured->code, 404, "it is the missing provider that stops it");
};

subtest "a private Hydra can still start a GitHub login" => sub {
    my $config = Hydra->config;
    local $config->{private} = "1";
    local $config->{github_client_id} = "abc";

    my $response = request(GET '/github-redirect?after=');
    isnt($response->code, 403, "the redirect to GitHub is not refused");
    like($response->header("Location"), qr{^https://github\.com/login/oauth/authorize},
        "it goes to GitHub");
};

subtest "with LDAP the form stays, but not for local accounts" => sub {
    my $config = Hydra->config;
    local $config->{ldap} = {};

    my $response = request(POST '/login',
        Referer => 'http://localhost/',
        Content => { username => 'alice', password => 'foobar' },
    );
    is($response->code, 403, "a local password is refused");
    like($response->content, qr{Bad username or password}, "by the login, not the endpoint");
};

done_testing;

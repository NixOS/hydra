use strict;
use warnings;
use Setup;
use KanidmContext;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request::Common;
use JSON::MaybeXS;
use URI;
use LWP::UserAgent;
use Test::PostgreSQL;
use Test::WWW::Mechanize::Catalyst;
use HTTP::CookieJar::LWP;
use Data::Dumper;

my $kanidm = KanidmContext->new();
$kanidm->start();
$kanidm->allow_passwords();
$kanidm->create_group('hydra_users');
$kanidm->create_group('hydra_admins');
# Group the IdP maps to a value Hydra's role_mapping does not mention.
$kanidm->create_group('hydra_strangers');
# Group the IdP maps to a value Hydra's role_mapping does not mention either,
# and which is the only group its user is in.
$kanidm->create_group('hydra_nobody');
$kanidm->create_user(
    'andy',
    groups => ['hydra_users', 'hydra_admins'],
    # Annoyingly password quality checks in kanidm cannot be disabled.
    password => 'kanidm credential',
);
$kanidm->create_user(
    'bert',
    groups => ['hydra_users'],
    password => 'kanidm credential',
);
$kanidm->create_user(
    'carl',
    groups => ['hydra_users', 'hydra_strangers'],
    password => 'kanidm credential',
);
# Only in hydra_nobody, whose IdP claim value is not in Hydra's role_mapping.
$kanidm->create_user(
    'dana',
    groups => ['hydra_nobody'],
    password => 'kanidm credential',
);
# Email address with a `+` in the local part, which is how subaddressed
# accounts (GitHub's noreply addresses, for one) turn up in claims.
$kanidm->create_user(
    'erin',
    groups => ['hydra_users'],
    mail => 'erin+ci@localhost',
    password => 'kanidm credential',
);
$kanidm->create_oauth2_client(
    name => 'hydra',
    redirect_uris => ['http://localhost/oidc-callback/test'],
    scopes => {
        hydra_users => ['openid', 'email', 'profile'],
        hydra_nobody => ['openid', 'email', 'profile'],
    },
    # The IdP calls its role claim `idp_roles` and its values have nothing to
    # do with Hydra's role names; the provider's role_mapping below is what
    # turns them into roles.
    claims => {
        idp_roles => {
            hydra_admins => ['powerusers'],
            hydra_users => ['builders'],
            hydra_strangers => ['idiots'],
            hydra_nobody => ['ghosts'],
        }
    }
);
print STDERR "kanidm running at ${\$kanidm->url} from ${\$kanidm->working_dir}\n";

my $ctx = test_context(
    hydra_config => <<"CFG"
        <oidc>
            <provider test>
                display_name = "Test Provider"
                discovery_url = "${\$kanidm->discovery_url('hydra')}"
                client_id = "hydra"
                client_secret = "${\$kanidm->get_oauth2_secret('hydra')}"
                ca_file = "${\$kanidm->ca_file}"
                # Kanidm does not implement RP-Initiated Logout, so we set this
                # manually to exercise the logout redirect path.
                end_session_endpoint = "${\$kanidm->url}/fake-end-session"
                role_claim = "idp_roles"
                <role_mapping>
                    powerusers = admin
                    builders = restart-jobs
                    builders = cancel-build
                    # The IdP's `idiots` and `ghosts` values are deliberately
                    # left out: they must not grant anything.
                </role_mapping>
            </provider>
        </oidc>
CFG
);

setup_catalyst_test($ctx);

# Drive a full OIDC login for $username and return the Mechanize object (which
# the caller may want to keep poking at) and the cookie jar holding the Hydra
# session cookie.
sub login_as {
    my ($username) = @_;

    # We need a better cookie jar implementation than the normal one, because HTTP::Cookies
    # does not seem to separate the cookies for kanidm & hydra running on different ports.
    # The kanidm cookies don't seem to get set in the Mechanize _at all_ without this.
    my $cookie_jar = HTTP::CookieJar::LWP->new();
    my $mech = Test::WWW::Mechanize::Catalyst->new(
        catalyst_app => 'Hydra',
        ssl_opts => {
           SSL_ca_file => $kanidm->ca_file,
        },
        cookie_jar => $cookie_jar,
    );
    $mech->allow_external(1);
    $mech->get_ok('/queue_summary');
    ok($mech->follow_link(text => 'Sign in with Test Provider'), "Follow login link");
    my $auth_url = $kanidm->authorization_url('hydra');
    like($mech->uri()->as_string, qr/^\Q$auth_url\E/, "redirect to login page");
    ok($mech->submit_form(
        form_id => 'login',
        fields => { username => $username }
    ), "Submit username form");
    ok($mech->submit_form(
        form_id => 'login',
        fields => { password => 'kanidm credential' }
    ), "Submit password form");
    # Kanidm can still have a page of its own in front of us after the
    # password: a consent page the first time this client logs in, or a
    # "resume" page for subsequent logins. Both just want their form
    # submitted. (kanidm has an option to skip consent, but it is not in a
    # released version in nixpkgs yet.)
    my $kanidm_url = $kanidm->url;
    foreach my $attempt (1 .. 3) {
        last unless $mech->uri->as_string =~ /^\Q$kanidm_url\E/;
        my @forms = $mech->forms;
        ok(scalar @forms, "[$username] kanidm still has a form for us to submit");
        last unless @forms;
        # Whatever the page is, its form is the only way forward.
        ok($mech->submit_form(form_number => 1), "[$username] submit kanidm form");
    }
    # Now we should be back in Hydra, on the queue_summary page
    like($mech->uri()->as_string, qr/\/queue_summary/, "redirect to queue_summary page");

    return ($mech, $cookie_jar);
}

# Fetch a page as the user logged in via login_as(), and return the roles Hydra
# ended up with for them.
sub roles_after_login {
    my ($username) = @_;

    my (undef, $cookie_jar) = login_as($username);
    my ($res, $c) = ctx_request(GET '/', Cookie => $cookie_jar->cookie_header('http://localhost'));
    is($res->code, 200, "[$username] fetching with ctx_request should succeed");

    return [sort map { $_->role } $c->user->userroles];
}

subtest "OIDC discovery configuration is loaded" => sub {
    require Hydra;
    my $config = Hydra->config->{oidc}->{provider}->{test};

    ok($config, "OIDC provider config exists");
    is($config->{display_name}, "Test Provider", "Display name is correct");
    is($config->{discovery_url}, $kanidm->discovery_url('hydra'), "Discovery URL is configured");

    # Discovery is done lazily on the first login attempt, not at config load
    # time, so the endpoints are only filled in after a request has gone
    # through the app.
    my $res = request(GET '/oidc-redirect/test?after=/');
    is($res->code, 302, "OIDC login redirect works");

    is($config->{issuer}, $kanidm->issuer('hydra'), "Issuer is set from discovery");
    is($config->{authorization_endpoint}, $kanidm->authorization_url('hydra'), "Auth endpoint is set");
    is($config->{token_endpoint}, $kanidm->token_url('hydra'), "Token endpoint is set");
    ok($config->{jwks_uri}, "JWKS URI is set");
    # Explicitly configured, so discovery must not have clobbered it.
    is($config->{end_session_endpoint}, $kanidm->url . "/fake-end-session", "Configured end_session_endpoint is kept");
};

subtest "OIDC redirect initiates authorization flow" => sub {
    my $req = request(GET '/oidc-redirect/test?after=/');

    is($req->code, 302, "Redirect to OIDC provider");

    my $location = URI->new($req->header('Location'));
    is($location->scheme . "://" . $location->host . ":" . $location->port . $location->path,
        $kanidm->authorization_url('hydra'), "Redirects to correct authorization endpoint");

    my %params = $location->query_form;
    is($params{response_type}, 'code', "Response type is code");
    is($params{client_id}, 'hydra', "Client ID is correct");
    like($params{redirect_uri}, qr/\/oidc-callback\/test/, "Redirect URI is correct");
    like($params{scope}, qr/openid/, "Scope includes openid");
    like($params{scope}, qr/email/, "Scope includes email");
    like($params{scope}, qr/profile/, "Scope includes profile");
    ok($params{state}, "State parameter is present");
    ok($params{nonce}, "Nonce parameter is present");
    is($params{code_challenge_method}, 'S256', "PKCE challenge method is S256");
    ok($params{code_challenge}, "PKCE code challenge is present");
};

subtest "OIDC redirect keeps 'after' on this host" => sub {
    # Browsers drop tabs and treat '\' as '/', so all of these would otherwise
    # end up as the protocol-relative '//evil.example'.
    foreach my $after ('//evil.example', '%09/evil.example', '/%0A/evil.example', '/%5C/evil.example') {
        my $res = request(GET "/oidc-redirect/test?after=$after");
        # ctx_request's $c is already finalized, so its session is reloaded
        # from the request cookie. Send the cookie we just got to see what was stored.
        my ($cookie) = ($res->header('Set-Cookie') // '') =~ /^([^;]+)/;
        my (undef, $c) = ctx_request(GET '/', Cookie => $cookie);
        is($c->session->{oidc}->{after}, '/evil.example', "after=$after is made a local path");
    }
};

subtest "OIDC login flow works end-to-end" => sub {
    my ($mech, $cookie_jar) = login_as('bert');

    # We should be logged in as the idm user, and have the roles in that role.
    # Make another request with ctx_request to get $c, but keep the cookies we just got from the
    # login process above.
    my ($res, $c) = ctx_request(GET '/', Cookie => $cookie_jar->cookie_header('http://localhost'));
    is($res->code, 200, "Fetching with ctx_request should succeed");
    like($c->user->username, qr/^test:/, "username is prefixed with OIDC IDM name");
    is($c->user->emailaddress, 'bert@localhost', "User has email from IDM");
    is([sort map { $_->role } $c->user->userroles], ['cancel-build', 'restart-jobs'], 'User has the roles the IDM maps to');

    # Session should remember the OIDC provider for RP-Initiated Logout
    is($c->session->{oidc_provider}, 'test', "OIDC provider stored in session");

    subtest "OIDC logout redirects to end_session_endpoint" => sub {
        # Don't auto-follow so we can inspect the redirect target without
        # actually hitting Kanidm's (non-existent) end_session endpoint.
        $mech->requests_redirectable([]);

        # GET /logout without a CSRF token must be rejected
        my $no_token = $mech->get('/logout');
        is($no_token->code, 403, "Logout without CSRF token is rejected");

        # Follow the real sign-out link which includes the CSRF token
        $mech->get('/');
        my $signout = $mech->find_link(text => 'Sign out');
        ok($signout, "Sign out link present");
        like($signout->url, qr/[?&]token=[0-9a-f]{64}/, "Sign out link carries CSRF token");

        my $res = $mech->get($signout->url);
        is($res->code, 302, "Logout issues a redirect");

        my $location = URI->new($res->header('Location'));
        my $end_session = $kanidm->url . "/fake-end-session";
        is($location->scheme . "://" . $location->host_port . $location->path,
            $end_session, "Redirects to the IdP end_session_endpoint");

        my %params = $location->query_form;
        is($params{client_id}, 'hydra', "client_id passed to end_session");
        like($params{post_logout_redirect_uri}, qr{^http://localhost},
            "post_logout_redirect_uri points back to Hydra");

        # Verify we're actually logged out
        $mech->requests_redirectable(['GET', 'HEAD']);
        my ($res2, $c2) = ctx_request(GET '/', Cookie => $cookie_jar->cookie_header('http://localhost'));
        ok(!$c2->user_exists, "User is logged out after /logout");
    };
};

subtest "OIDC role mappings" => sub {
    # The IdP sends `powerusers` and `builders` in its `idp_roles` claim; the
    # roles Hydra ends up with are its own, because that is what the
    # provider's role_mapping says they mean.
    is(roles_after_login('andy'),
        ['admin', 'cancel-build', 'restart-jobs'],
        "IdP values the role_mapping mentions become Hydra roles, for every group the user is in");

    is(roles_after_login('bert'),
        ['cancel-build', 'restart-jobs'],
        "One IdP value can map to several Hydra roles");

    # The IdP presents `builders` and `idiots` for this user, and only
    # `builders` is in the role_mapping.
    is(roles_after_login('carl'),
        ['cancel-build', 'restart-jobs'],
        "IdP values the role_mapping does not mention grant nothing");

    is(roles_after_login('dana'),
        [],
        "A user whose only IdP value is unmapped gets no roles");
};

subtest "OIDC login with a + in the email address" => sub {
    my ($mech, $cookie_jar) = login_as('erin');

    my ($res, $c) = ctx_request(GET '/', Cookie => $cookie_jar->cookie_header('http://localhost'));
    is($res->code, 200, "Fetching with ctx_request should succeed");
    is($c->user->emailaddress, 'erin+ci@localhost',
        "The + in the IdP's email address does not stop the login, and is kept");
    is([sort map { $_->role } $c->user->userroles], ['cancel-build', 'restart-jobs'],
        "Roles are set as usual");
};

done_testing;

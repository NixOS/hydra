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
$kanidm->create_oauth2_client(
    name => 'hydra',
    redirect_uris => ['http://localhost/oidc-callback/test'],
    scopes => { hydra_users => ['openid', 'email', 'profile']},
    claims => {
        hydra_roles => {
            hydra_admins => ['admin'],
            hydra_users => ['restart_jobs', 'bump_to_front', 'cancel_build'],
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
            </provider>
        </oidc>
CFG
);

Catalyst::Test->import('Hydra');

subtest "OIDC static config is loaded, discovery is lazy" => sub {
    require Hydra;
    my $config = Hydra->config->{oidc}->{provider}->{test};

    ok($config, "OIDC provider config exists");
    is($config->{display_name}, "Test Provider", "Display name is correct");
    ok($config->{client_secret}, "Client secret is loaded");
    # Discovery endpoints are NOT fetched at startup — they're resolved on
    # first login so an unreachable IdP doesn't block Hydra startup.
    ok(!$config->{authorization_endpoint}, "Auth endpoint not yet resolved (lazy)");
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

subtest "OIDC login flow works end-to-end" => sub {
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
        fields => { username => 'bert' }
    ), "Submit username form");
    ok($mech->submit_form(
        form_id => 'login',
        fields => { password => 'kanidm credential' }
    ), "Submit password form");
    # If the consent page is displayed, submit that.
    # (kanidm now has an option to skip this, but it's not in a released version in nixpkgs yet)
    if ($mech->title =~ /Consent Required/) {
        ok($mech->submit_form(form_id => 'login'), "Submit consent form");
    }
    # Now we should be back in Hydra, on the queue_summary page
    like($mech->uri()->as_string, qr/\/queue_summary/, "redirect to queue_summary page");

    # We should be logged in as the idm user, and have the roles in that role.
    # Make another request with ctx_request to get $c, but keep the cookies we just got from the
    # login process above.
    my ($res, $c) = ctx_request(GET '/', Cookie => $cookie_jar->cookie_header('http://localhost'));
    is($res->code, 200, "Fetching with ctx_request should succeed");
    like($c->user->username, qr/^test:/, "username is prefixed with OIDC IDM name");
    is($c->user->emailaddress, 'bert@localhost', "User has email from IDM");
    is([sort map { $_->role } $c->user->userroles], ['bump-to-front', 'cancel-build', 'restart-jobs'], 'User has roles from IDM');

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

done_testing;

use strict;
use warnings;
use Hydra::Config qw(signinMethods);
use Test2::V0;

# The set of ways a visitor can sign in, which is what the sign-in menu is built
# from: it offers what is configured, and `POST /login` accepts a password only
# when the form is one of those ways.

# Clear the legacy LDAP env var so it doesn't leak into these tests.
delete $ENV{"HYDRA_LDAP_CONFIG"};

subtest "out of the box there is a Hydra account" => sub {
    my $methods = signinMethods({}, "");
    is(scalar @$methods, 1, "one way to sign in");
    is($methods->[0]{label}, "Sign in with a Hydra account", "named for what it is");
    is($methods->[0]{href}, "#hydra-signin", "opens a dialog rather than a URL");
    ok($methods->[0]{form}, "which the template has to be told about");
};

subtest "only 0 turns local authentication off" => sub {
    for my $case (["unset", {}], ["1", { local_auth_enabled => "1" }],
        ["empty", { local_auth_enabled => "" }])
    {
        my ($what, $config) = @$case;
        my $methods = signinMethods($config, "");
        is(scalar @$methods, 1, "$what means on, the same as search_enable and private");
        is($methods->[0]{label}, "Sign in with a Hydra account", "$what still signs in with a Hydra account");
    }
    is(scalar @{signinMethods({ local_auth_enabled => "0" }, "")}, 0, "0 means off");
};

subtest "one provider is then the only way in" => sub {
    my $methods = signinMethods({
        local_auth_enabled => "0",
        oidc => { provider => { authentik => { display_name => "Authentik" } } },
    }, "/jobset/nixpkgs/master");
    is(scalar @$methods, 1, "one way to sign in");
    is($methods->[0]{label}, "Sign in with Authentik", "labelled with the display name");
    is($methods->[0]{href}, "/oidc-redirect/authentik?after=%2Fjobset%2Fnixpkgs%2Fmaster",
        "points at the provider, remembering where to come back to");
    ok(!$methods->[0]{form}, "not a dialog");
};

subtest "a provider without a display name names itself" => sub {
    my $methods = signinMethods({
        local_auth_enabled => "0",
        oidc => { provider => { foo => {} } },
    }, "");
    is($methods->[0]{label}, "Sign in with OIDC (foo)", "the name is a fallback, not the default");
};

subtest "GitHub is a way to sign in too" => sub {
    my $methods = signinMethods({ local_auth_enabled => "0", github_client_id => "abc" }, "/");
    is(scalar @$methods, 1, "one way to sign in");
    is($methods->[0]{label}, "Sign in with GitHub", "GitHub");
    is($methods->[0]{href}, "/github-redirect?after=%2F", "pointing at the redirect");
    ok(!$methods->[0]{form}, "not a dialog");
};

subtest "providers come before the password form" => sub {
    my $methods = signinMethods({
        oidc => { provider => {
            zanzibar => { display_name => "Zanzibar" },
            auth => { display_name => "Auth" },
        } },
    }, "");
    is(scalar @$methods, 3, "two providers and the form");
    is($methods->[0]{label}, "Sign in with Auth", "providers are listed by name");
    is($methods->[1]{label}, "Sign in with Zanzibar", "all of them");
    is($methods->[2]{label}, "Sign in with a Hydra account", "the password form stays last, where it has always been");
};

subtest "LDAP keeps the form when local authentication is off" => sub {
    my $methods = signinMethods({ local_auth_enabled => "0", ldap => { config => {} } }, "");
    is(scalar @$methods, 1, "one way to sign in");
    ok($methods->[0]{form}, "still the password form");
    is($methods->[0]{label}, "Sign in with LDAP",
        "but not claiming to be a Hydra account, which is no longer one");
};

subtest "the deprecated LDAP environment variable keeps it too" => sub {
    local $ENV{"HYDRA_LDAP_CONFIG"} = "/etc/hydra/ldap.yml";
    my $methods = signinMethods({ local_auth_enabled => "0" }, "");
    is(scalar @$methods, 1, "one way to sign in");
    is($methods->[0]{label}, "Sign in with LDAP", "and labelled for LDAP");
};

subtest "the page to come back to cannot break out of the query string" => sub {
    my $methods = signinMethods({ local_auth_enabled => "0", github_client_id => "abc" }, "/a b&c=d");
    is($methods->[0]{href}, "/github-redirect?after=%2Fa%20b%26c%3Dd", "escaped");
};

subtest "no page to come back to is not a problem" => sub {
    my $methods = signinMethods({ local_auth_enabled => "0", github_client_id => "abc" }, undef);
    is($methods->[0]{href}, "/github-redirect?after=", "an empty `after'");
};

done_testing;

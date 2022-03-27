use strict;
use warnings;
use Setup;
use LDAPContext;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request::Common;
use JSON::MaybeXS;

my $ldap = LDAPContext->new();
my $users = {
    unrelated => $ldap->add_user("unrelated_user"),
    admin => $ldap->add_user("admin_user"),
    not_admin => $ldap->add_user("not_admin_user"),
    many_roles => $ldap->add_user("many_roles"),
    many_roles_one_group => $ldap->add_user("many_roles_one_group"),
};

$ldap->add_group("hydra_admin", $users->{"admin"}->{"username"});
$ldap->add_group("hydra-admin", $users->{"not_admin"}->{"username"});
$ldap->add_group("hydra_one_group_many_roles", $users->{"many_roles_one_group"}->{"username"});

$ldap->add_group("hydra_create-projects", $users->{"many_roles"}->{"username"});
$ldap->add_group("hydra_restart-jobs", $users->{"many_roles"}->{"username"});
$ldap->add_group("hydra_bump-to-front", $users->{"many_roles"}->{"username"});
$ldap->add_group("hydra_cancel-build", $users->{"many_roles"}->{"username"});


my $ctx = test_context(
    before_init => sub {
        my ($ctx) = @_;
        write_file($ctx->{"tmpdir"} . "/password.conf", "bindpw = ${\$ldap->{'root_password'}}");
    },
    hydra_config => <<CFG
        <ldap>
            <config>
                <credential>
                    class = Password
                    password_field = password
                    password_type = self_check
                </credential>
                <store>
                    class = LDAP
                    ldap_server = ${\$ldap->server_url()}
                    <ldap_server_options>
                        timeout = 30
                        debug = 0
                    </ldap_server_options>
                    binddn = "cn=root,dc=example"
                    include password.conf
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
                hydra_admin = admin
                hydra_create-projects = create-projects
                hydra_cancel-build = cancel-build
                hydra_bump-to-front = bump-to-front
                hydra_restart-jobs = restart-jobs

                hydra_one_group_many_roles = create-projects
                hydra_one_group_many_roles = cancel-build
                hydra_one_group_many_roles = bump-to-front
            </role_mapping>
        </ldap>
CFG
);

Catalyst::Test->import('Hydra');

subtest "Valid login attempts" => sub {
    my %users_to_roles = (
        unrelated => [],
        admin => ["admin"],
        not_admin => [],
        many_roles => [ "create-projects", "restart-jobs", "bump-to-front", "cancel-build" ],
        many_roles_one_group => [ "create-projects", "bump-to-front", "cancel-build" ],
    );
    for my $username (keys %users_to_roles) {
        my $user = $users->{$username};
        my $roles = $users_to_roles{$username};

        subtest "Verifying $username" => sub {
            my $req = request(POST '/login',
                Referer => 'http://localhost/',
                Accept => 'application/json',
                Content => {
                    username => $user->{"username"},
                    password => $user->{"password"}
                }
            );

            is($req->code, 302, "The login redirects");
            my $data = decode_json($req->content());
            is($data->{"username"}, $user->{"username"}, "Username matches");
            is($data->{"emailaddress"}, $user->{"email"}, "Email matches");
            is([sort @{$data->{"userroles"}}], [sort @$roles], "Roles match");
        };
    }
};

# Logging in with an invalid user is rejected
is(request(POST '/login',
    Referer => 'http://localhost/',
    Content => {
        username => 'alice',
        password => 'foobar'
    }
)->code, 403, "Logging in with invalid credentials does not work");



done_testing;

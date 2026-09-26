use strict;
use warnings;
use Setup;
my $ctx = test_context();
use HTTP::Request::Common;
use Test2::V0;
setup_catalyst_test($ctx);
require Hydra::Schema;
my $db = $ctx->db();
my $user = $db->resultset('Users')->create({ username => 'alice', emailaddress => 'alice@invalid.org', password => '!' });
$user->setPassword('foobar');
my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);
my $login = request(POST '/login', Referer => 'http://localhost', Content => {
        username => 'alice',
        password => 'foobar',
    });
is($login->code, 302);
my $cookie = $login->header("set-cookie");
my $my_jobs = request(GET '/dashboard/alice/my-jobs-tab', Accept => 'application/json', Cookie => $cookie);
ok($my_jobs->is_success);
my $content = $my_jobs->content();
like($content, qr/empty_dir/);
ok(!($content =~ /fails/));
ok(!($content =~ /succeed_with_failed/));

# Email addresses set through the preferences form are checked like the ones
# coming from an identity provider.
my $admin = $db->resultset('Users')->create({ username => 'emailcheck', emailaddress => '', password => '!', type => 'hydra' });
$admin->setPassword('foobar');
$admin->userroles->create({ role => 'admin' });
my $admin_login = request(POST '/login', Referer => 'http://localhost', Content => {
        username => 'emailcheck',
        password => 'foobar',
    });
is($admin_login->code, 302);
my $admin_cookie = $admin_login->header("set-cookie");

my $bad_email = request(PUT '/user/alice', Referer => 'http://localhost', Cookie => $admin_cookie, Content => {
        fullname => 'Alice',
        emailaddress => 'alice@localhost, mallory@localhost',
    });
is($bad_email->code, 400, "a malformed email address is rejected");
is($db->resultset('Users')->find('alice')->emailaddress, 'alice@invalid.org', "... and not stored");

my $subaddress = request(PUT '/user/alice', Referer => 'http://localhost', Cookie => $admin_cookie, Content => {
        fullname => 'Alice',
        emailaddress => 'alice+ci@localhost',
    });
ok($subaddress->is_success, "an email address with a + is accepted");
is($db->resultset('Users')->find('alice')->emailaddress, 'alice+ci@localhost', "... and stored");

my $no_email = request(PUT '/user/alice', Referer => 'http://localhost', Cookie => $admin_cookie, Content => {
        fullname => 'Alice',
        emailaddress => '',
    });
ok($no_email->is_success, "not setting an email address is still allowed");
done_testing;

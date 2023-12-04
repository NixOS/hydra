use strict;
use warnings;
use Setup;
my $ctx = test_context();
use HTTP::Request::Common;
use Test2::V0;
use Catalyst::Test ();
Catalyst::Test->import('Hydra');
require Hydra::Schema;
require Hydra::Model::DB;
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
ok($content =~ /empty_dir/);
ok(!($content =~ /fails/));
ok(!($content =~ /succeed_with_failed/));
done_testing;

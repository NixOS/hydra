use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context(
    hydra_config => q|
    <runcommand>
      command = cp "$HYDRA_JSON" "$HYDRA_DATA/joboutput.json"
    </runcommand>
|);

require Catalyst::Test;
Catalyst::Test->import('Hydra');
use HTTP::Request::Common qw(GET);

my $db = $ctx->db();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "runcommand.nix",
    build => 1,
);
my $build = $builds->{"metrics"};

ok(sendNotifications(), "Notifications execute successfully.");

my $runlog = $build->runcommandlogs->find({});
ok($runlog->uuid, "The log's uuid is saved.");

my $get1 = request(GET '/build/' . $build->id . '/runcommandlog/' . $runlog->uuid);
ok($get1->is_success, "GET /build/{id}/runcommandlog/{uuid} succeeded.");

my $get2 = request(GET '/runcommandlog/' . $runlog->uuid);
ok($get2->is_success, "GET /runcommandlog/{uuid} succeeded.");

my $get3 = request(GET '/runcommandlog/some-invalid-or-nonexistent-uuid');
ok(!$get3->is_success, "GET'ing invalid uuid failed.");

my $get4a = request(GET '/build/' . $build->id . '/runcommandlog/' . $runlog->uuid . '/raw');
is($get4a->code, 302, "GET /build/{id}/runcommandlog/{uuid}/raw is a redirect.");
my $get4b = request(GET $get4a->header('location'));
ok($get4b->is_success, "GET /build/{id}/runcommandlog/{uuid}/raw succeeded.");

my $get5a = request(GET '/build/' . $build->id . '/runcommandlog/some-invalid-or-nonexistent-uuid/raw');
is($get5a->code, 302, "GET /raw of invalid uuid is a redirect.");
my $get5b = request(GET $get5a->header("location"));
ok(!$get5b->is_success, "GET /raw of invalid uuid failed.");

done_testing;

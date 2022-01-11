use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json encode_json);

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');
use HTTP::Request::Common qw(POST PUT GET DELETE);

# This test verifies that creating, reading, updating, and deleting a jobset via
# the HTTP API works as expected.

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Create a user to log in to
my $user = $db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

my $project = $db->resultset('Projects')->create({name => 'tests', displayname => 'Tests', owner => 'alice'});

my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset),               "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");

my $failing;
for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with return code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build '".$build->job."' from jobs/basic.nix should be finished.");

    if ($build->job eq "fails") {
        is($newbuild->buildstatus, 1, "Build 'fails' from jobs/basic.nix should have buildstatus 1.");
        $failing = $build;
        last;
    }
}

isnt($failing, undef, "We should have the failing build to restart");

# Login and save cookie for future requests
my $req = request(POST '/login',
    Referer => 'http://localhost/',
    Content => {
        username => 'alice',
        password => 'foobar'
    }
);
is($req->code, 302, "Logging in gets a 302");
my $cookie = $req->header("set-cookie");


subtest 'Restart the failing build' => sub {
    my $restart = request(PUT '/build/' . $failing->id . '/restart',
        Accept => 'application/json',
        Content_Type => 'application/json',
        Cookie => $cookie,
    );
    is($restart->code, 302, "Restarting 302's back to the build");
    is($restart->header("location"), "http://localhost/build/" . $failing->id);

    my $newbuild = $db->resultset('Builds')->find($failing->id);
    is($newbuild->finished, 0, "Build 'fails' from jobs/basic.nix should not be finished.");
};

done_testing;

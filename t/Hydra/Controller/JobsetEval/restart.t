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

my ($eval, @evals) = $jobset->jobsetevals;
my ($abortedBuild, $failedBuild, @builds) = queuedBuildsForJobset($jobset);

isnt($eval, undef, "We have an evaluation to restart");

# Make the build be aborted
isnt($abortedBuild, undef, "We should have the aborted build to restart");
$abortedBuild->update({
    finished => 1,
    buildstatus => 3,
    stoptime => 1,
    starttime => 1,
 });

# Make the build be failed
isnt($failedBuild, undef, "We should have the failed build to restart");
$failedBuild->update({
    finished => 1,
    buildstatus => 5,
    stoptime => 1,
    starttime => 1,
 });

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


subtest 'Restart all aborted JobsetEval builds' => sub {
    my $restart = request(PUT '/eval/' . $eval->id . '/restart-aborted',
        Accept => 'application/json',
        Content_Type => 'application/json',
        Cookie => $cookie,
    );
    is($restart->code, 302, "Restarting 302's back to the build");
    is($restart->header("location"), "http://localhost/eval/" . $eval->id);

    my $newAbortedBuild = $db->resultset('Builds')->find($abortedBuild->id);
    is($newAbortedBuild->finished, 0, "The aborted build is no longer finished");

    my $newFailedBuild = $db->resultset('Builds')->find($failedBuild->id);
    is($newFailedBuild->finished, 1, "The failed build is still finished");
};

subtest 'Restart all failed JobsetEval builds' => sub {
    my $restart = request(PUT '/eval/' . $eval->id . '/restart-failed',
        Accept => 'application/json',
        Content_Type => 'application/json',
        Cookie => $cookie,
    );
    is($restart->code, 302, "Restarting 302's back to the build");
    is($restart->header("location"), "http://localhost/eval/" . $eval->id);

    my $newFailedBuild = $db->resultset('Builds')->find($failedBuild->id);
    is($newFailedBuild->finished, 0, "The failed build is no longer finished");
};

done_testing;

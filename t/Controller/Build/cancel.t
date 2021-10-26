use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use JSON qw(decode_json encode_json);

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

my ($build, @builds) = queuedBuildsForJobset($jobset);
is($build->finished, 0, "Unbuilt build should not be finished.");
is($build->buildstatus, undef, "Unbuilt build should be undefined.");


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


subtest 'Cancel the build' => sub {
    my $restart = request(PUT '/build/' . $build->id . '/cancel',
        Accept => 'application/json',
        Content_Type => 'application/json',
        Cookie => $cookie,
    );
    is($restart->code, 302, "Restarting 302's back to the build");
    is($restart->header("location"), "http://localhost/build/" . $build->id);

    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build 'fails' from jobs/basic.nix should be 'finished'.");
    is($newbuild->buildstatus, 4, "Build 'fails' from jobs/basic.nix should be canceled.");
};

done_testing;

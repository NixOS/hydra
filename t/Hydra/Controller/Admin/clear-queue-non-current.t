use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json encode_json);
use File::Copy;

my %ctx = test_init(
    hydra_config => q|
# No caching for PathInput plugin, otherwise we get wrong values
# (as it has a 30s window where no changes to the file are considered).
path_input_cache_validity_seconds = 0
|
);

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');
use HTTP::Request::Common qw(POST PUT GET DELETE);

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Create a user to log in to
my $user = $db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

my $project = $db->resultset('Projects')->create({name => 'tests', displayname => 'Tests', owner => 'alice'});

my $scratchdir = $ctx{tmpdir} . "/scratch";
my $jobset = createBaseJobset("basic", "default.nix", $scratchdir);

subtest "Create and evaluate our job at version 1" => sub {
    mkdir $scratchdir or die "mkdir($scratchdir): $!\n";

    # Note: this recreates the raw derivation and skips
    # the generated config.nix because we never actually
    # build anything.
    open(my $fh, ">", "$scratchdir/default.nix");
    print $fh <<EOF;
{
  example = derivation {
    builder = "./builder.sh";
    name = "example";
    system = builtins.currentSystem;
    version = 1;
  };
}
EOF
    close($fh);

    ok(evalSucceeds($jobset),               "Evaluating our default.nix should exit with return code 0");
    is(nrQueuedBuildsForJobset($jobset), 1, "Evaluating our default.nix should result in 1 builds");
};

subtest "Update and evaluate our job to version 2" => sub {
    open(my $fh, ">", "$scratchdir/default.nix");
    print $fh <<EOF;
{
  example = derivation {
    builder = "./builder.sh";
    name = "example";
    system = builtins.currentSystem;
    version = 2;
  };
}
EOF
    close($fh);


    ok(evalSucceeds($jobset),               "Evaluating our default.nix should exit with return code 0");
    is(nrQueuedBuildsForJobset($jobset), 2, "Evaluating our default.nix should result in 1 more build, resulting in 2 queued builds");
};

my ($firstBuild, $secondBuild, @builds) = queuedBuildsForJobset($jobset)->search(
    {},
    { order_by => { -asc => 'id' }}
);
subtest "Validating the first build" => sub {
    isnt($firstBuild, undef, "We have our first build");
    is($firstBuild->id, 1, "The first build is ID 1");
    is($firstBuild->finished, 0, "The first build is not yet finished");
    is($firstBuild->buildstatus, undef, "The first build status is null");
};

subtest "Validating the second build" => sub {
    isnt($secondBuild, undef, "We have our second build");
    is($secondBuild->id, 2, "The second build is ID 2");
    is($secondBuild->finished, 0, "The second build is not yet finished");
    is($secondBuild->buildstatus, undef, "The second build status is null");
};

is(@builds, 0, "No other builds were created");

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

subtest 'Cancel queued, non-current builds' => sub {
    my $restart = request(PUT '/admin/clear-queue-non-current',
        Accept => 'application/json',
        Content_Type => 'application/json',
        Referer => '/admin/example-referer',
        Cookie => $cookie,
    );
    is($restart->code, 302, "Canceling 302's back to the build");
    is($restart->header("location"), "/admin/example-referer", "We're redirected back to the referer");
};

subtest "Validating the first build is canceled" => sub {
    my $build = $db->resultset('Builds')->find($firstBuild->id);
    is($build->finished, 1, "Build should be 'finished'.");
    is($build->buildstatus, 4, "Build should be canceled.");
};

subtest "Validating the second build is not canceled" => sub {
    my $build = $db->resultset('Builds')->find($secondBuild->id);
    is($build->finished, 0, "Build should be unfinished.");
    is($build->buildstatus, undef, "Build status should be null.");
};

done_testing;

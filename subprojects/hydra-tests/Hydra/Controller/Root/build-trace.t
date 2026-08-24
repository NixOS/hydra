use strict;
use warnings;
use Setup;
use File::Basename ();
use JSON::MaybeXS qw(decode_json);

my %ctx = test_init(
    nix_config => qq|
    experimental-features = ca-derivations
    |,
    # A `file:` store is not a local store to `isLocalStore`, and the binary
    # cache routes serve from nothing else.
    use_external_destination_store => 0,
);

use Test2::V0;
use HTTP::Request::Common;
setup_catalyst_test($ctx{context});

require Hydra::Schema;
require Hydra::Helper::Nix;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset = createBaseJobset($db, "content-addressed", "content-addressed.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating jobs/content-addressed.nix succeeds");
my @builds = queuedBuildsForJobset($jobset);
ok(runBuilds($ctx{context}, @builds), "Building jobs/content-addressed.nix succeeds");

my ($build) = grep { $_->nixname eq "empty-dir" } @builds;
$build->discard_changes();
is($build->buildstatus, 0, "The content-addressed build succeeded");

my $drv = File::Basename::basename($build->drvpath);
my $outPath = File::Basename::basename($build->buildoutputs->find({ name => "out" })->path);

subtest "serving a build trace" => sub {
    my $response = request(GET "/build-trace-v2/$drv/out.doi");
    ok($response->is_success, "A built content-addressed derivation has a build trace");

    # A build trace entry, whose `outPath` carries no store directory:
    # https://nix.dev/manual/nix/2.35/protocols/json/build-trace-entry
    is(decode_json($response->content),
        { outPath => $outPath, signatures => [] },
        "naming the output it resolved to");
};

subtest "a build trace that does not exist" => sub {
    my $response = request(GET "/build-trace-v2/00000000000000000000000000000000-nope.drv/out.doi");
    is($response->code, 404, "404s");
    is($response->content, "does not exist\n", "from the route itself");
};

# A key the constraints reject never reaches the route, so it answers something
# other than the route's own "does not exist".
subtest "a malformed key" => sub {
    for my $bad ("$drv/out", "not-a-store-path/out.doi") {
        my $response = request(GET "/build-trace-v2/$bad");
        isnt($response->content, "does not exist\n", "'$bad' is not served");
    }
};

done_testing;

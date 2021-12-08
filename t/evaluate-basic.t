use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();
my $db = $ctx->db;

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

# Most basic test case, no parameters
my $jobset = createBaseJobset("basic", "basic.nix", $ctx->jobsdir);

ok(evalSucceeds($jobset),               "Evaluating jobs/basic.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 3, "Evaluating jobs/basic.nix should result in 3 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with return code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build '".$build->job."' from jobs/basic.nix should be finished.");
    my $expected = $build->job eq "fails" ? 1 : $build->job =~ /with_failed/ ? 6 : 0;
    is($newbuild->buildstatus, $expected, "Build '".$build->job."' from jobs/basic.nix should have buildstatus $expected.");
}

done_testing;

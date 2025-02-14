use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init(
    nix_config => qq|
    experimental-features = ca-derivations
    |,
);

require Hydra::Schema;
require Hydra::Model::DB;

use JSON::MaybeXS;

use HTTP::Request::Common;
use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("content-addressed", "content-addressed.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating jobs/content-addressed.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 5, "Evaluating jobs/content-addressed.nix should result in 4 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/content-addressed.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build '".$build->job."' from jobs/content-addressed.nix should be finished.");
    my $expected = $build->job eq "fails" ? 1 : $build->job =~ /with_failed/ ? 6 : 0;
    is($newbuild->buildstatus, $expected, "Build '".$build->job."' from jobs/content-addressed.nix should have buildstatus $expected.");

    my $response = request("/build/".$build->id);
    ok($response->is_success, "The 'build' page for build '".$build->job."' should load properly");

    if ($newbuild->buildstatus == 0) {
      my $buildOutputs = $newbuild->buildoutputs;
      for my $output ($newbuild->buildoutputs) {
        # XXX: This hardcodes /nix/store/.
        # It's fine because in practice the nix store for the tests will be of
        # the form `/some/thing/nix/store/`, but it would be cleaner if there
        # was a way to query Nix for its store dir?
        like(
          $output->path, qr|/nix/store/|,
          "Output '".$output->name."' of build '".$build->job."' should be a valid store path"
        );
      }
    }

}

isnt(<$ctx{deststoredir}/realisations/*>, "", "The destination store should have the realisations of the built derivations registered");

done_testing;


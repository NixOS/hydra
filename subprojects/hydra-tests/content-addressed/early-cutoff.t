use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init(
    nix_config => qq|
    experimental-features = ca-derivations
    |,
);

use Test2::V0;

my $db = $ctx{context}->db();

# Loop to reproduce the flaky "One downstream build should be cached" race.
my $iterations = $ENV{HYDRA_EARLY_CUTOFF_ITERATIONS} // 10;

for my $iter (1 .. $iterations) {
    my $project = $db->resultset('Projects')->create({
        name => "tests-$iter",
        displayname => "",
        owner => "root",
    });

    my $jobset = createBaseJobset(
        $db,
        "content-addressed-early-cutoff-$iter",
        "content-addressed-early-cutoff.nix",
        $ctx{jobsdir},
    );

    ok(evalSucceeds($ctx{context}, $jobset), "[$iter] Evaluating early cutoff jobs should exit with return code 0");
    is(nrQueuedBuildsForJobset($jobset), 4, "[$iter] Should queue 4 early cutoff builds");

    my @builds = queuedBuildsForJobset($jobset);
    ok(runBuilds($ctx{context}, @builds), "[$iter] Building all early cutoff jobs should exit with code 0");

    for my $build (@builds) {
        my $newbuild = $db->resultset('Builds')->find($build->id);
        is($newbuild->finished, 1, "[$iter] Build '".$build->job."' should be finished.");
        is($newbuild->buildstatus, 0, "[$iter] Build '".$build->job."' should have buildstatus 0.");
    }

    # earlyCutoffUpstream1 and earlyCutoffUpstream2 differ but produce the same
    # content-addressed output. Building earlyCutoffDownstream1 should let
    # earlyCutoffDownstream2 be cached, since its resolved input is identical.
    my $upstream1 = $db->resultset('Builds')->find({ jobset_id => $jobset->id, job => "earlyCutoffUpstream1" });
    my $upstream2 = $db->resultset('Builds')->find({ jobset_id => $jobset->id, job => "earlyCutoffUpstream2" });

    my $upstream1_out = $upstream1->buildoutputs->find({ name => "out" });
    my $upstream2_out = $upstream2->buildoutputs->find({ name => "out" });
    is($upstream1_out->path, $upstream2_out->path,
        "[$iter] Both upstream builds should resolve to the same content-addressed output path");

    my $downstream1 = $db->resultset('Builds')->find({ jobset_id => $jobset->id, job => "earlyCutoffDownstream1" });
    my $downstream2 = $db->resultset('Builds')->find({ jobset_id => $jobset->id, job => "earlyCutoffDownstream2" });

    my $downstream1_out = $downstream1->buildoutputs->find({ name => "out" });
    my $downstream2_out = $downstream2->buildoutputs->find({ name => "out" });
    is($downstream1_out->path, $downstream2_out->path,
        "[$iter] Both downstream builds should create the same content-addressed output path");

    my $passed = ok($downstream1->iscachedbuild || $downstream2->iscachedbuild,
        "[$iter] One downstream build should be cached");

    unless ($passed) {
        for my $b ($upstream1, $upstream2, $downstream1, $downstream2) {
            my $out = $b->buildoutputs->find({ name => "out" });
            diag(sprintf("build id=%d job=%s out=%s iscached=%s start=%s stop=%s",
                $b->id, $b->job, ($out ? $out->path : "<undef>"),
                $b->iscachedbuild, $b->starttime // "?", $b->stoptime // "?"));
        }
    }
}

done_testing;

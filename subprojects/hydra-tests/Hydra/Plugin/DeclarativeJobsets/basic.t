use feature 'unicode_strings';
use strict;
use warnings;
use Test2::V0;
use Setup;

my $ctx = test_context();
my $db = $ctx->db;

my $project = $db->resultset('Projects')->create({
    name => "tests",
    displayname => "",
    owner => "root",
    declfile => "declarative/project.json",
    decltype => "path",
    declvalue => $ctx->jobsdir,
});

subtest "Evaluating and building the top .jobsets jobset" => sub {
    # This logic lives in the Project controller.
    # Not great to duplicate it here.
    # TODO: refactor and deduplicate.
    my $jobset = $project->jobsets->create({
        name=> ".jobsets",
        nixexprinput => "",
        nixexprpath => "",
        emailoverride => "",
        triggertime => time,
    });

    ok(evalSucceeds($jobset), "Evaluating the declarative jobsets with return code 0");
    is(nrQueuedBuildsForJobset($jobset), 1, "We should have exactly 1 build queued, to build the jobsets data");

    (my $build) = queuedBuildsForJobset($jobset);

    is($build->job, "jobsets", "The only job should be jobsets");
    ok(runBuild($build), "Build should exit with return code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");

    ok(sendNotifications(), "Notifications execute successfully.");
};

subtest "Validating a new jobset appears" => sub {
    my $jobset = $project->jobsets->find({ name => "my-jobset" });
    ok($jobset, "We have a jobset");
    is($jobset->description, "my-declarative-jobset", "The jobset's description matches");

    subtest "Evaluating and building that jobset works" => sub {
        ok(evalSucceeds($jobset), "Evaluating the new jobset with return code 0");
        is(nrQueuedBuildsForJobset($jobset), 1, "We should have exactly 1 build queued");

        (my $build) = queuedBuildsForJobset($jobset);

        is($build->job, "one_job", "The only job should be jobsets");
        ok(runBuild($build), "Build should exit with return code 0");
        my $newbuild = $db->resultset('Builds')->find($build->id);
        is($newbuild->finished, 1, "Build should be finished.");
        is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");
    };
};
done_testing;

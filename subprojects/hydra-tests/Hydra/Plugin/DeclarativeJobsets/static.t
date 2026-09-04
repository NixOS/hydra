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
    declfile => "declarative/static-project.json",
    decltype => "path",
    declvalue => $ctx->jobsdir,
});

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

subtest "Evaluating the static declarative specification" => sub {
    ok(evalSucceeds($ctx, $jobset), "Evaluating the static declarative spec with return code 0");

    my $declared = $project->jobsets->find({ name => "my-static-jobset" });
    ok($declared, "The declared jobset exists");
    is($declared->description, "my-static-jobset", "The jobset's description matches");
};

subtest "A stale evaluation error is cleared by the next successful check" => sub {
    # Simulate a previous transient failure, e.g. the declarative input
    # temporarily failing to fetch.
    $jobset->update({ errormsg => "transient fetch failure", errortime => time - 60 });

    ok(evalSucceeds($ctx, $jobset), "Re-evaluating the static declarative spec with return code 0");
    is($jobset->errormsg, "", "The stale evaluation error is cleared");
};

done_testing;

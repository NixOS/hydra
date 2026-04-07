use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;

use Test2::V0;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "broken-constituent", "broken-constituent.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating jobs/broken-constituent.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 0, "Evaluating jobs/broken-constituent.nix should not queue any builds");

like(
    $jobset->errormsg,
    qr/^does-not-exist: does not exist$/m,
    "Evaluating jobs/broken-constituent.nix should log an error for does-not-exist");
like(
    $jobset->errormsg,
    qr/^does-not-evaluate: error: assertion 'false' failed/m,
    "Evaluating jobs/broken-constituent.nix should log an error for does-not-evaluate");

done_testing;

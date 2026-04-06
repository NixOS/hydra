use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init();

use JSON::MaybeXS;

use HTTP::Request::Common;
use Test2::V0;
setup_catalyst_test($ctx{context});

require Hydra::Schema;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "content-addressed", "content-addressed.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating jobs/content-addressed.nix without the experimental feature should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 0, "Evaluating jobs/content-addressed.nix without the experimental Nix feature should result in 0 build");

done_testing;

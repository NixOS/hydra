use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;

use JSON::MaybeXS;

use HTTP::Request::Common;
use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "content-addressed", "content-addressed.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset),                  "Evaluating jobs/content-addressed.nix without the experimental feature should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 0, "Evaluating jobs/content-addressed.nix without the experimental Nix feature should result in 0 build");

done_testing;

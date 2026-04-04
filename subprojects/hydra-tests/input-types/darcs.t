use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a darcs repo as input.
testScmInput(
  db => $db,
  type => 'darcs',
  expr => 'darcs-input.nix',
  uri => 'darcs-repo',
  update => 'jobs/darcs-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
);

done_testing;

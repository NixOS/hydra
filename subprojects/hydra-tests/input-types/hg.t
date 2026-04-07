use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a hg repo as input.
testScmInput(
  db => $db,
  type => 'hg',
  expr => 'hg-input.nix',
  uri => 'hg-repo',
  update => 'jobs/hg-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
  ctx => $ctx{context},
);

done_testing;

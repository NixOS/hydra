use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a bzr repo as input.
testScmInput(
  db => $db,
  type => 'bzr',
  expr => 'bzr-input.nix',
  uri => 'bzr-repo',
  update => 'jobs/bzr-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
);

done_testing;

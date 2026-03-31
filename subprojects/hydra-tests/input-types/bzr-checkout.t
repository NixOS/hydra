use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a bzr checkout as input.
testScmInput(
  db => $db,
  type => 'bzr-checkout',
  expr => 'bzr-checkout-input.nix',
  uri => 'bzr-checkout-repo',
  update => 'jobs/bzr-checkout-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
  ctx => $ctx{context},
);

done_testing;

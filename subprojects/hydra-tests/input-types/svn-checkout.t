use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a svn checkout as input.
testScmInput(
  db => $db,
  type => 'svn-checkout',
  expr => 'svn-checkout-input.nix',
  uri => 'svn-checkout-repo',
  update => 'jobs/svn-checkout-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
);

done_testing;

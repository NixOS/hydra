use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a svn repo as input.
testScmInput(
  db => $db,
  type => 'svn',
  expr => 'svn-input.nix',
  uri => 'svn-repo',
  update => 'jobs/svn-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
  ctx => $ctx{context},
);

done_testing;

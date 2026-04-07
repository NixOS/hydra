use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a deep git clone as input.
testScmInput(
  db => $db,
  type => 'git',
  name => 'deepgit',
  expr => 'deepgit-input.nix',
  uri => 'git-repo master 1',
  update => 'jobs/git-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
  ctx => $ctx{context},
);

done_testing;

use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

use Test2::V0;

my $db = $ctx{context}->db();

# Tests the creation of a Hydra jobset using a git revision as input.
testScmInput(
  db => $db,
  type => 'git',
  name => 'git-rev',
  expr => 'git-rev-input.nix',
  uri => 'git-repo 7f60df502b96fd54bbfa64dd94b56d936a407701',
  update => 'jobs/git-rev-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
);

done_testing;

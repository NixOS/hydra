use strict;
use Setup;
use TestScmInput;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Tests the creation of a Hydra jobset using a deep git clone as input.
testScmInput(
  type => 'git',
  name => 'deepgit',
  expr => 'deepgit-input.nix',
  uri => 'git-repo master 1',
  update => 'jobs/git-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
);

done_testing;

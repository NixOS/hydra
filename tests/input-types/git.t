use strict;
use Cwd;
use Setup;
use TestScmInput;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Tests the creation of a Hydra jobset using a git repo as input.
testScmInput(
  type => 'git',
  expr => 'git-input.nix',
  uri => 'git-repo',
  update => 'jobs/git-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
);

done_testing;

use strict;
use Cwd;
use Setup;
use TestScmInput;

(my $datadir, my $pgsql) = test_init();

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
  datadir => $datadir,
  testdir => getcwd,
);

done_testing;

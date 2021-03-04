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

# Tests the creation of a Hydra jobset using a svn repo as input.
testScmInput(
  type => 'svn',
  expr => 'svn-input.nix',
  uri => 'svn-repo',
  update => 'jobs/svn-update.sh',

  # directories
  datadir => $datadir,
  testdir => getcwd,
);

done_testing;

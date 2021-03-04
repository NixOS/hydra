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

# Tests the creation of a Hydra jobset using a hg repo as input.
testScmInput(
  type => 'hg',
  expr => 'hg-input.nix',
  uri => 'hg-repo',
  update => 'jobs/hg-update.sh',

  # directories
  datadir => $datadir,
  testdir => getcwd,
);

done_testing;

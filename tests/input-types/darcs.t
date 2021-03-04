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

# Tests the creation of a Hydra jobset using a darcs repo as input.
testScmInput(
  type => 'darcs',
  expr => 'darcs-input.nix',
  uri => 'darcs-repo',
  update => 'jobs/darcs-update.sh',

  # directories
  datadir => $datadir,
  testdir => getcwd,
);

done_testing;

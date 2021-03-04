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

# Tests the creation of a Hydra jobset using a svn checkout as input.
testScmInput(
  type => 'svn-checkout',
  expr => 'svn-checkout-input.nix',
  uri => 'svn-checkout-repo',
  update => 'jobs/svn-checkout-update.sh',

  # directories
  datadir => $datadir,
  testdir => getcwd,
);

done_testing;

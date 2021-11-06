use strict;
use warnings;
use Setup;
use TestScmInput;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Tests the creation of a Hydra jobset using a bzr repo as input.
testScmInput(
  type => 'bzr',
  expr => 'bzr-input.nix',
  uri => 'bzr-repo',
  update => 'jobs/bzr-update.sh',

  # directories
  datadir => $ctx{tmpdir},
  testdir => $ctx{testdir},
  jobsdir => $ctx{jobsdir},
);

done_testing;

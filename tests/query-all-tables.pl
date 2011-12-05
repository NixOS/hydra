use strict;
use Hydra::Schema;
use Hydra::Helper::Nix;

my $db = openHydraDB;

my @sources = $db->sources;
my $nrtables = scalar(@sources);

use Test::Simple tests => 44;

foreach my $source (@sources) {
  my $title = "Basic select query for $source";
  if ($source eq "SchemaVersion") {
      ok(scalar($db->resultset($source)->all) == 1, $title);
  } elsif( $source !~ m/^(LatestSucceeded|JobStatus|ActiveJobs)/) {
      ok(scalar($db->resultset($source)->all) == 0, $title);
  } 
  else {
      ok(scalar($db->resultset($source)->search({},{ bind => ["", "", ""] })) == 0, $title);
  }
}


package Setup;

use strict;
use Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(hydra_setup);

sub hydra_setup {
  my ($db) = @_;
  $db->resultset('Users')->create({ username => "root", emailaddress => 'root@email.com', password => '' });
}

1;

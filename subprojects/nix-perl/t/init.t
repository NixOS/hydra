use strict;
use warnings;
use Test2::V0;

use Nix::Store;

my $s = Nix::Store->new("dummy://");

# Base name only: the bindings do not know about the store directory.
my $res = $s->isValidPath("g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bar");

ok(!$res, "should not have path");

done_testing;

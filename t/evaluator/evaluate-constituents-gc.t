use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => 'constituents.nix',
);

my $constituentA = $builds->{"constituentA"};
my $directAggregate = $builds->{"direct_aggregate"};
my $indirectAggregate = $builds->{"indirect_aggregate"};

is(system('nix-store', '--delete', $constituentA->drvpath), 256, "Deleting a constituent derivation fails");
is(system('nix-store', '--delete', $directAggregate->drvpath), 256, "Deleting the direct aggregate derivation fails");
is(system('nix-store', '--delete', $indirectAggregate->drvpath), 256, "Deleting the indirect aggregate derivation fails");

done_testing;

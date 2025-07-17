use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

my $expression = 'constituents.nix';
my $jobsetCtx = $ctx->makeJobset(
    expression => $expression,
);
my $builds = $ctx->evaluateJobset(
    jobset => $jobsetCtx->{"jobset"},
    expression => $expression,
    build => 0,
);

my $constituentA = $builds->{"constituentA"};
my $directAggregate = $builds->{"direct_aggregate"};
my $indirectAggregate = $builds->{"indirect_aggregate"};
my $mixedAggregate = $builds->{"mixed_aggregate"};

# Ensure that we get exactly the aggregates we expect
my %expected_constituents = (
    'direct_aggregate' => {
        'constituentA' => 1,
    },
    'indirect_aggregate' => {
        'constituentA' => 1,
    },
    'mixed_aggregate' => {
        # Note that `constituentA_alias` becomes `constituentA`, because
        # the shorter name is preferred
        'constituentA' => 1,
        'constituentB' => 1,
    },
);

my $rs = $ctx->db->resultset('AggregateConstituents')->search(
    {},
    {
        join     => [ 'aggregate', 'constituent' ],  # Use correct relationship names
        columns  => [],
        '+select' => [ 'aggregate.job', 'constituent.job' ],
        '+as'     => [ 'aggregate_job', 'constituent_job' ],
    }
);

my %actual_constituents;
while (my $row = $rs->next) {
    my $aggregate_job   = $row->get_column('aggregate_job');
    my $constituent_job = $row->get_column('constituent_job');
    $actual_constituents{$aggregate_job} //= {};
    $actual_constituents{$aggregate_job}{$constituent_job} = 1;
}

is(\%actual_constituents, \%expected_constituents, "Exact aggregate constituents as expected");

# Check that deletion also doesn't work accordingly

is(system('nix-store', '--delete', $constituentA->drvpath), 256, "Deleting a constituent derivation fails");
is(system('nix-store', '--delete', $directAggregate->drvpath), 256, "Deleting the direct aggregate derivation fails");
is(system('nix-store', '--delete', $indirectAggregate->drvpath), 256, "Deleting the indirect aggregate derivation fails");

done_testing;

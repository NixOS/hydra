use strict;
use Setup;
my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Data::Dumper;
use Test2::V0;
use Test2::Compare qw(compare strict_convert);

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# This test checks a matrix of jobset configuration options for constraint violations.

my @types = ( 0, 1, 2 );
my @nixexprinputs = ( undef, "input" );
my @nixexprpaths = ( undef, "path" );
my @flakes = ( undef, "flake" );

my @expected_failing;
my @expected_succeeding = (
    {
        "name" => "test",
        "emailoverride" => "",
        "type" => 0,
        "nixexprinput" => "input",
        "nixexprpath" => "path",
        "flake" => undef,
    },
    {
        "name" => "test",
        "emailoverride" => "",
        "type" => 1,
        "nixexprinput" => undef,
        "nixexprpath" => undef,
        "flake" => "flake",
    },
);

# Checks if two Perl hashes (in scalar context) contain the same data.
# Returns 0 if they are different and 1 if they are the same.
sub test_scenario_matches {
    my ($first, $second) = @_;

    my $ret = compare($first, $second, \&strict_convert);

    if (defined $ret == 1) {
        return 0;
    } else {
        return 1;
    }
}

# Construct a matrix of parameters that should violate the Jobsets table's constraints.
foreach my $type (@types) {
    foreach my $nixexprinput (@nixexprinputs) {
        foreach my $nixexprpath (@nixexprpaths) {
            foreach my $flake (@flakes) {
                my $hash = {
                    "name" => "test",
                    "emailoverride" => "",
                    "type" => $type,
                    "nixexprinput" => $nixexprinput,
                    "nixexprpath" => $nixexprpath,
                    "flake" => $flake,
                };

                push(@expected_failing, $hash) if (!grep { test_scenario_matches($_, $hash) } @expected_succeeding);
            };
        };
    };
};

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

# Validate that the list of parameters that should fail the constraints do indeed fail.
subtest "Expected constraint failures" => sub {
    my $count = 1;
    foreach my $case (@expected_failing) {
        subtest "Case $count: " . Dumper ($case) => sub {
            dies {
                # Necessary, otherwise cases will fail because the `->create`
                # will throw an exception due to an expected constraint failure
                # (which will cause the `ok()` to be skipped, leading to no
                # assertions in the subtest).
                is(1, 1);

                ok(
                    !$project->jobsets->create($case),
                    "Expected jobset to violate constraints"
                );
            };
        };

        $count++;
    };
};

# Validate that the list of parameters that should not fail the constraints do indeed succeed.
subtest "Expected constraint successes" => sub {
    my $count = 1;
    foreach my $case (@expected_succeeding) {
        subtest "Case $count: " . Dumper ($case) => sub {
            my $jobset = $project->jobsets->create($case);

            ok(
                $jobset,
                "Expected jobset to not violate constraints"
            );

            # Delete the jobset so the next jobset won't violate the name constraint.
            $jobset->delete;
        };

        $count++;
    };
};

done_testing;

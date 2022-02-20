use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => 'constituents.nix',
);

my $constituentBuildA = $builds->{"constituentA"};
my $constituentBuildB = $builds->{"constituentB"};

my $eval = $constituentBuildA->jobsetevals->first();
is($eval->evaluationerror->errormsg, "");

subtest "Verifying the direct aggregate" => sub {
    my $aggBuild = $builds->{"direct_aggregate"};
    is($aggBuild->constituents->first()->id, $constituentBuildA->id, "The ID of the constituent is correct");
};

subtest "Verifying the indirect aggregate" => sub {
    my $indirectBuild = $builds->{"indirect_aggregate"};
    is($indirectBuild->constituents->first()->id, $constituentBuildA->id, "The ID of the constituent is correct");
};

subtest "Verifying a mix of direct and indirect aggregate references" => sub {
    my $mixedBuild = $builds->{"mixed_aggregate"};
    my ($constituentA, $constituentB) = $mixedBuild->constituents()->search({}, {order_by => { -asc => "job"} });
    is($constituentA->id, $constituentBuildA->id, "The ID of the constituent is correct");
    is($constituentB->id, $constituentBuildB->id, "The ID of the constituent is correct");
};

done_testing;

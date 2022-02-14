use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

# Test build products

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "build-products.nix",
    build      => 1
);

subtest "For the build job 'simple'" => sub {
    my $build = $builds->{"simple"};

    is($build->finished,    1, "Build should have finished");
    is($build->buildstatus, 0, "Build should have buildstatus 0");

    my $buildproduct = $build->buildproducts->next;
    is($buildproduct->name, "text.txt", "We should have \"text.txt\"");
};

subtest "For the build job 'with_spaces'" => sub {
    my $build = $builds->{"with_spaces"};

    is($build->finished,    1, "Build should have finished");
    is($build->buildstatus, 0, "Build should have buildstatus 0");

    my $buildproduct = $build->buildproducts->next;
    is($buildproduct->name, "some text.txt", "We should have: \"some text.txt\"");
};

done_testing;

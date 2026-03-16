use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "meta.nix",
    build => 1
);

my $build = $builds->{"full-of-meta"};

is($build->finished, 1, "Build should be finished.");
is($build->description, "This is the description of the job.", "Wrong description extracted from the build.");
is($build->license, "MIT, BSD", "Wrong licenses extracted from the build.");
is($build->homepage, "https://example.com/", "Wrong homepage extracted from the build.");
is($build->maintainers, 'alice@example.com, bob@not.found', "Wrong maintainers extracted from the build.");

done_testing;

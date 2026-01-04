use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context(
  nix_config => q|
    system-features = test-system-feature
  |
);

my $builds = $ctx->makeAndEvaluateJobset(
  expression => "default-machine-file.nix",
  build => 1,
);

my $build = $builds->{"requireExperimentalFeatures"};
is($build->finished, 1, "Build should be finished.");
is($build->buildstatus, 0, "Build status should be zero");

done_testing;

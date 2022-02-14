use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::Exec;

my $ctx    = test_context();
my $builds = $ctx->makeAndEvaluateJobset(
    expression => "one-job.nix",
    build      => 1
);

subtest "Updating GC roots" => sub {
    my ($res, $stdout, $stderr) = captureStdoutStderr(5, ("hydra-update-gc-roots"));
    is($res, 0, "hydra-update-gc-roots should exit zero");
    if ($res != 0) {
        print "gc roots stdout: $stdout\n";
        print "gc roots stderr: $stderr";
    }
};

done_testing;

use strict;
use warnings;
use Setup;

my $ctx = test_context();
my $db = $ctx->db();

require Hydra::Helper::Nix;

use Test2::V0;

subtest "constructRunCommandLogPath" => sub {
    my $builds = $ctx->makeAndEvaluateJobset(
        expression => "basic.nix",
    );
    my $build = $builds->{"empty_dir"};
    my $runlog = $db->resultset('RunCommandLogs')->create({
        job_matcher => "*:*:*",
        build_id => $build->get_column('id'),
        command => "bogus",
    });

    # constructRunCommandLogPath -> getHydraPath reads $ENV{HYDRA_DATA}
    local $ENV{HYDRA_DATA} = $ctx->{central}{hydra_data};
    like(
        Hydra::Helper::Nix::constructRunCommandLogPath($runlog),
        qr@/runcommand-logs/[0-9a-f]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@,
        "The constructed RunCommandLog path is sufficiently bucketed and UUID-like."
    );

    my $badlog = $db->resultset('RunCommandLogs')->new({ uuid => "../../../etc/passwd" });
    ok(
        dies { Hydra::Helper::Nix::constructRunCommandLogPath($badlog) },
        "Expected invalid UUID to be rejected and not have a path constructed for it.",
    );
};

done_testing;

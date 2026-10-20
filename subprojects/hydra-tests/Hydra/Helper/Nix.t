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

subtest "registerRoot keeps an existing plain file root it cannot write" => sub {
    local $ENV{HYDRA_CONFIG} = $ctx->{central}{hydra_config_file};
    local $ENV{NIX_STATE_DIR} = $ctx->tmpdir;
    local $ENV{LOGNAME} = "registerRoot-test";

    my $storeDir = $ctx->{central}{nix_store_dir};
    my $path = Hydra::StorePath::parseStorePath($storeDir, "$storeDir/7r03087nqvxvb295wlp78pahh1m9fcmg-foo");
    my $link = Hydra::Helper::Nix::gcRootFor($path);

    # Read-only stands in for a root owned by another user (e.g. hydra-queue-runner).
    open(my $fh, ">", $link) or die "cannot create $link: $!";
    close $fh;
    chmod 0444, $link;

    ok(lives { Hydra::Helper::Nix::registerRoot($path) }, "registerRoot does not die") or note($@);
    ok(-f $link && !-l $link, "The existing root is left in place.");
};

done_testing;

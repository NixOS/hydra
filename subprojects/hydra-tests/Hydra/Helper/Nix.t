use strict;
use warnings;
use Setup;
use File::Temp;

my $ctx = test_context();
my $db = $ctx->db();

require Hydra::Helper::Nix;

use Test2::V0;

my $dir = File::Temp->newdir();
my $machines = "$dir/machines";

open(my $fh, '>', $machines) or die "Could not open file '$machines' $!";
print $fh q|
# foobar
root@ip x86_64-darwin /sshkey 15 15 big-parallel,kvm,nixos-test - base64key

# Macs
# root@bar x86_64-darwin /sshkey 6 1 big-parallel
root@baz aarch64-darwin /sshkey 4 1 big-parallel

root@bux i686-linux,x86_64-linux /var/sshkey 1 1 kvm,nixos-test benchmark
root@lotsofspace    i686-linux,x86_64-linux    /var/sshkey   1   1  kvm,nixos-test   benchmark

|;
close $fh;

# getMachines -> getHydraConfig -> getHydraPath needs HYDRA_CONFIG
my $got_machines = do {
    local $ENV{HYDRA_CONFIG} = $ctx->{central}{hydra_config_file};
    local $ENV{NIX_REMOTE_SYSTEMS} = $machines;
    Hydra::Helper::Nix::getMachines();
};

is($got_machines, {
    'root@ip' => {
        'systemTypes' => ["x86_64-darwin"],
        'maxJobs' => 15,
        'speedFactor' => 15,
        'supportedFeatures' => ["big-parallel", "kvm", "nixos-test" ],
        'mandatoryFeatures' => [ ],
    },
    'root@baz' => {
        'systemTypes' => [ "aarch64-darwin" ],
        'maxJobs' => 4,
        'speedFactor' => 1,
        'supportedFeatures' => ["big-parallel"],
        'mandatoryFeatures' => [],
    },
    'root@bux' => {
        'systemTypes' => [ "i686-linux", "x86_64-linux" ],
        'maxJobs' => 1,
        'speedFactor' => 1,
        'supportedFeatures' => [ "kvm", "nixos-test", "benchmark" ],
        'mandatoryFeatures' => [ "benchmark" ],
    },
    'root@lotsofspace' => {
        'systemTypes' => [ "i686-linux", "x86_64-linux" ],
        'maxJobs' => 1,
        'speedFactor' => 1,
        'supportedFeatures' => [ "kvm", "nixos-test", "benchmark" ],
        'mandatoryFeatures' => [ "benchmark" ],
    },

}, ":)");

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

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

$ENV{'NIX_REMOTE_SYSTEMS'} = $machines;

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

is(Hydra::Helper::Nix::getMachines(), {
    'root@ip' => {
        'systemTypes' => ["x86_64-darwin"],
        'sshKeys' => '/sshkey',
        'maxJobs' => 15,
        'speedFactor' => 15,
        'supportedFeatures' => ["big-parallel", "kvm", "nixos-test" ],
        'mandatoryFeatures' => [ ],
    },
    'root@baz' => {
        'systemTypes' => [ "aarch64-darwin" ],
        'sshKeys' => '/sshkey',
        'maxJobs' => 4,
        'speedFactor' => 1,
        'supportedFeatures' => ["big-parallel"],
        'mandatoryFeatures' => [],
    },
    'root@bux' => {
        'systemTypes' => [ "i686-linux", "x86_64-linux" ],
        'sshKeys' => '/var/sshkey',
        'maxJobs' => 1,
        'speedFactor' => 1,
        'supportedFeatures' => [ "kvm", "nixos-test", "benchmark" ],
        'mandatoryFeatures' => [ "benchmark" ],
    },
    'root@lotsofspace' => {
        'systemTypes' => [ "i686-linux", "x86_64-linux" ],
        'sshKeys' => '/var/sshkey',
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

    like(
        Hydra::Helper::Nix::constructRunCommandLogPath($runlog),
        qr@/runcommand-logs/[0-9a-f]{2}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}@,
        "The constructed RunCommandLog path is sufficiently bucketed and UUID-like."
    );
};

done_testing;

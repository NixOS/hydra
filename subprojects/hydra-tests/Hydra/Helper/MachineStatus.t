use strict;
use warnings;
use Test::More;
use Storable qw(dclone);
use Hydra::Helper::MachineStatus qw(machinesFromQueueRunner withMachineSteps);

my $native = '11111111-1111-4111-8111-111111111111';
my $linux = '22222222-2222-4222-8222-222222222222';
my $data = { machines => {
    $native => {
        registrationId => $native, hostname => 'mac-6',
        systems => ['aarch64-darwin', 'x86_64-darwin'],
        jobs => ['/nix/store/native.drv'],
        hasCapacity => 1, maxJobs => 2,
        supportedFeatures => ['benchmark'], mandatoryFeatures => [],
        stats => { nrStepsDone => 8, avgStepBuildTimeMs => 1500 },
    },
    $linux => {
        registrationId => $linux, hostname => 'mac-6',
        systems => ['x86_64-linux'], jobs => ['linux.drv'],
        hasCapacity => 0, maxJobs => 1,
        supportedFeatures => ['kvm'], mandatoryFeatures => ['recursive-nix'],
    },
} };
my $before = dclone($data);
my $machines = machinesFromQueueRunner($data);
is(scalar keys %$machines, 2, 'same-host registrations both reach the web view');
is($machines->{$native}->{hostname}, 'mac-6', 'display hostname is distinct from registration identity');
is($machines->{$native}->{primarySystemType}, 'aarch64-darwin', 'native system retained');
is($machines->{$linux}->{primarySystemType}, 'x86_64-linux', 'Linux system retained');
is($machines->{$native}->{hasCapacity}, 1, 'native capacity retained');
is($machines->{$linux}->{hasCapacity}, 0, 'Linux capacity retained separately');
is_deeply($machines->{$linux}->{supportedFeatures}, ['kvm', 'recursive-nix'], 'feature mapping retained');
is($machines->{$native}->{nrStepsDone}, 8, 'live registration step count used');
is($machines->{$native}->{avgStepBuildTime}, 1.5, 'live millisecond duration converted to seconds');
is_deeply($data, $before, 'input snapshot not mutated');

my $steps = [
    { machine => 'mac-6', drvpath => '/nix/store/native.drv', stepnr => 1 },
    { machine => 'mac-6', drvpath => '/nix/store/linux.drv', stepnr => 2 },
    { machine => 'mac-7', drvpath => '/nix/store/linux.drv', stepnr => 3 },
    { machine => 'mac-6', drvpath => '/nix/store/old.drv', stepnr => 4 },
];
my $with = withMachineSteps($machines, $steps);
is_deeply([map { $_->{stepnr} } @{$with->{$native}->{steps}}], [1], 'native row shows only its own live job');
is_deeply([map { $_->{stepnr} } @{$with->{$linux}->{steps}}], [2], 'Linux row shows only its own live job, normalizing drv basenames');
ok(!exists $machines->{$native}->{steps}, 'attaching steps does not mutate roster');
ok($with->{$linux}->{hasReportedJobs}, 'active worker job list is retained independently of DB details');
my $not_yet_in_db = withMachineSteps({ $linux => { %{$machines->{$linux}}, jobs => ['prefetch.drv'] } }, []);
is_deeply($not_yet_in_db->{$linux}->{steps}, [], 'unavailable step details are not invented');
ok($not_yet_in_db->{$linux}->{hasReportedJobs}, 'worker is not labelled idle just because step details are unavailable');

my $legacy_roster = { 'ssh://nix@mac-6' => {}, '' => {} };
my $legacy_before = dclone($legacy_roster);
my $legacy = withMachineSteps($legacy_roster, [
    @$steps, { machine => '', drvpath => '/nix/store/local.drv', stepnr => 5 },
]);
is_deeply([map { $_->{stepnr} } @{$legacy->{'ssh://nix@mac-6'}->{steps}}], [1, 2, 4], 'legacy SSH hostname matching preserved');
is_deeply([map { $_->{stepnr} } @{$legacy->{''}->{steps}}], [5], 'legacy localhost matching preserved');
is_deeply($legacy_roster, $legacy_before, 'missing legacy stats do not mutate the input roster');

my $old_rpc = machinesFromQueueRunner({ machines => { 'mac-6' => { hostname => 'mac-6', systems => ['aarch64-darwin'] } } });
is_deeply([map { $_->{stepnr} } @{withMachineSteps($old_rpc, $steps)->{'mac-6'}->{steps}}], [1, 2, 4], 'web adapter still accepts the old hostname-keyed endpoint during upgrades');
is_deeply(machinesFromQueueRunner({ machines => {} }), {}, 'empty registry remains empty');

done_testing;

package Hydra::Helper::MachineStatus;

use strict;
use warnings;
use Exporter 'import';
use File::Basename qw(basename);

our @EXPORT_OK = qw(machinesFromQueueRunner withMachineSteps);

sub machinesFromQueueRunner {
    my ($data) = @_;
    my %machines;
    foreach my $id (keys %{$data->{machines} || {}}) {
        my $machine = $data->{machines}->{$id};
        my $systems = $machine->{systems} || [];
        my $stats = $machine->{stats} || {};
        $machines{$id} =
            { registrationId => $machine->{registrationId}
            , hostname => $machine->{hostname} // $id
            , jobs => $machine->{jobs} || []
            , systemTypes => $systems
            , maxJobs => $machine->{maxJobs}
            , speedFactor => $machine->{speedFactor}
            , supportedFeatures => [ @{$machine->{supportedFeatures} || []}, @{$machine->{mandatoryFeatures} || []} ]
            , mandatoryFeatures => [ @{$machine->{mandatoryFeatures} || []} ]
            , primarySystemType => $systems->[0]
            , hasCapacity => $machine->{hasCapacity}
            , hasDynamicCapacity => $machine->{hasDynamicCapacity}
            , hasStaticCapacity => $machine->{hasStaticCapacity}
            , score => $machine->{score}
            , stats => $stats
            , memTotal => $machine->{totalMem}
            , nrStepsDone => $stats->{nrStepsDone}
            , avgStepBuildTime => ($stats->{avgStepBuildTimeMs} // 0) / 1000
            };
    }
    return \%machines;
}

sub machineName {
    my ($name) = @_;
    $name ||= "localhost";
    $name =~ s/^.*@//;
    return $name;
}

sub withMachineSteps {
    my ($machines, $steps) = @_;
    my %reported;
    foreach my $id (keys %$machines) {
        my $machine = $machines->{$id};
        next unless defined $machine->{registrationId};
        my $name = machineName($machine->{hostname} // $id);
        $reported{$name}->{basename($_)} = 1 foreach @{$machine->{jobs} || []};
    }
    # The database read follows the worker snapshot. A newly dispatched job
    # may therefore have a busy row but no registration owner in that snapshot.
    # Show this uncertainty for the host instead of calling its workers idle.
    my %unassigned;
    foreach my $step (@$steps) {
        my $name = machineName($step->{machine});
        my $reported_jobs = $reported{$name} || {};
        $unassigned{$name} = 1 unless $reported_jobs->{basename($step->{drvpath})};
    }
    my %result;
    foreach my $id (keys %$machines) {
        my $machine = $machines->{$id};
        my $stats = $machine->{stats} || {};
        my $name = machineName($machine->{hostname} // $id);
        my %active = map { basename($_) => 1 } @{$machine->{jobs} || []};
        # BuildSteps stores a hostname, not a worker UUID. A live registration's
        # own job list distinguishes native and Linux siblings on that host.
        my @owned = grep {
            machineName($_->{machine}) eq $name &&
            (!defined($machine->{registrationId}) || $active{basename($_->{drvpath})})
        } @$steps;
        $result{$id} =
            { %$machine, steps => \@owned
            , hasReportedJobs => (scalar(@{$machine->{jobs} || []}) || ($stats->{currentJobs} // 0)) ? 1 : 0
            , hasUnassignedSteps => defined($machine->{registrationId}) && $unassigned{$name} ? 1 : 0
            };
    }
    return \%result;
}

1;

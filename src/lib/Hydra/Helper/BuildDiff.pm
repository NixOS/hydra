package Hydra::Helper::BuildDiff;

use utf8;
use strict;
use warnings;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    buildDiff
);

sub cmpBuilds {
    my ($left, $right) = @_;
    return $left->get_column('job') cmp $right->get_column('job')
        || $left->get_column('system') cmp $right->get_column('system')
}

sub buildDiff {
    # $builds is the list of current builds
    # $builds2 is the list of previous (to-be-compared-to) builds
    my ($builds, $builds2) = @_;

    $builds  = [sort { cmpBuilds($a, $b) } @{$builds}];
    $builds2 = [sort { cmpBuilds($a, $b) } @{$builds2}];

    my $ret = {
        stillSucceed => [],
        stillFail => [],
        nowSucceed => [],
        nowFail => [],
        new => [],
        removed => [],
        unfinished => [],
        aborted => [],
        failed => [],
    };

    my $n = 0;
    foreach my $build (@{$builds}) {
        my $aborted = $build->finished != 0 && (
            # aborted
            $build->buildstatus == 3
            # cancelled
            || $build->buildstatus == 4
            # timeout
            || $build->buildstatus == 7
            # log limit exceeded
            || $build->buildstatus == 10
        );
        my $d;
        my $found = 0;
        while ($n < scalar(@{$builds2})) {
            my $build2 = @{$builds2}[$n];
            my $d = cmpBuilds($build, $build2);
            last if $d == -1;
            if ($d == 0) {
                $n++;
                $found = 1;
                if ($aborted) {
                    # do nothing
                } elsif ($build->finished == 0 || $build2->finished == 0) {
                    push @{$ret->{unfinished}}, $build;
                } elsif ($build->buildstatus == 0 && $build2->buildstatus == 0) {
                    push @{$ret->{stillSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus != 0) {
                    push @{$ret->{stillFail}}, $build;
                } elsif ($build->buildstatus == 0 && $build2->buildstatus != 0) {
                    push @{$ret->{nowSucceed}}, $build;
                } elsif ($build->buildstatus != 0 && $build2->buildstatus == 0) {
                    push @{$ret->{nowFail}}, $build;
                } else { die; }
                last;
            }
            my $job_system = { job => $build2->get_column('job'), system => $build2->get_column('system') };
            push @{$ret->{removed}}, $job_system;
            $n++;
        }
        if ($aborted) {
            push @{$ret->{aborted}}, $build;
        } else {
            push @{$ret->{new}}, $build if !$found;
        }
        if (defined $build->buildstatus && $build->buildstatus != 0) {
            push @{$ret->{failed}}, $build;
        }
    }

    return $ret;
}

1;

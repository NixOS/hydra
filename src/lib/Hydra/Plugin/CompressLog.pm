package Hydra::Plugin::CompressLog;

use strict;
use warnings;
use utf8;
use parent 'Hydra::Plugin';
use Hydra::Helper::CatalystUtils;

sub stepFinished {
    my ($self, $step, $logPath) = @_;

    my $doCompress = $self->{config}->{'compress_build_logs'} // '1';
    my $silent = $self->{config}->{'compress_build_logs_silent'} // '0';
    my $compression = $self->{config}->{'compress_build_logs_compression'} // 'bzip2';

    if (not -e $logPath or $doCompress ne "1") {
        return;
    }

    if ($silent ne '1') {
        print STDERR "compressing '$logPath' with $compression...\n";
    }

    if ($compression eq 'bzip2') {
        system('bzip2', '--force', $logPath);
    } elsif ($compression eq 'zstd') {
        system('zstd', '-T0', $logPath);
    } else {
        print STDERR "unknown compression type '$compression'\n";
    }
}

1;

package Hydra::Plugin::CompressLog;

use strict;
use utf8;
use parent 'Hydra::Plugin';
use Hydra::Helper::CatalystUtils;

sub stepFinished {
    my ($self, $step, $logPath) = @_;

    my $doCompress = $self->{config}->{'compress_build_logs'} // "1";

    if ($doCompress eq "1" && -e $logPath) {
        print STDERR "compressing ‘$logPath’...\n";
        system("bzip2", "--force", $logPath);
    }
}

1;

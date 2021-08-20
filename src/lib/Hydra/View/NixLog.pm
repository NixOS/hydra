package Hydra::View::NixLog;

use strict;
use base qw/Catalyst::View/;
use Hydra::Helper::CatalystUtils;

sub process {
    my ($self, $c) = @_;

    my $logPath = $c->stash->{logPath};

    $c->response->content_type('text/plain; charset=utf-8');

    my $fh = IO::Handle->new();

    my $tail = int($c->stash->{tail} // "0");

    if ($logPath =~ /\.bz2$/) {
        my $doTail = $tail ? " tail -n '$tail' |" : "";
        open $fh, "bzip2 -dc < '$logPath' | $doTail" or die;
    } else {
        if ($tail) {
            open $fh, "tail -n '$tail' '$logPath' |" or die;
        } else {
            open $fh, "<$logPath" or die;
        }
    }
    binmode($fh);

    setCacheHeaders($c, 365 * 24 * 60 * 60) if $c->stash->{finished};

    $c->response->body($fh);

    return 1;
}

1;

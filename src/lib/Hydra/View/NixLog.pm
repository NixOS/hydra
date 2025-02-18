package Hydra::View::NixLog;

use strict;
use warnings;
use base qw/Catalyst::View/;
use Hydra::Helper::CatalystUtils;

sub tail {
    my ($filehandle, $n) = @_;
    my @lines;
    my $line_count = 0;

    while (my $line = <$filehandle>) {
        $lines[$line_count % $n] = $line;
        $line_count++;
    }

    my $start = $line_count > $n ? $line_count % $n : 0;
    my $end = $line_count > $n ? $n : $line_count;

    my $result = "";
    for my $i (0 .. $end - 1) {
        $result .= $lines[($start + $i) % $n];
    }
    return $result;
}

sub process {
    my ($self, $c) = @_;

    my $logPath = $c->stash->{logPath};

    $c->response->content_type('text/plain; charset=utf-8');

    my $logFh = IO::Handle->new();

    my $tailLines = int($c->stash->{tail} // "0");

    if ($logPath =~ /\.zst$/) {
        open($logFh, "-|", "zstd", "-dc", $logPath) or die;
    } elsif ($logPath =~ /\.bz2$/) {
        open($logFh, "-|", "bzip2", "-dc", $logPath) or die;
    } else {
        open($logFh, "<", $logPath) or die;
    }

    setCacheHeaders($c, 365 * 24 * 60 * 60) if $c->stash->{finished};

    if ($tailLines > 0) {
      my $logEnd = tail($logFh, $tailLines);
      $c->response->body($logEnd);
      return 1;
    }

    binmode($logFh);
    $c->response->body($logFh);

    return 1;
}

1;

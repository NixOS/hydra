package Hydra::Helper::LogEndpoints;

use strict;
use warnings;
use Exporter;
use Hydra::Helper::CatalystUtils;

our @ISA = qw(Exporter);
our @EXPORT = qw(showLog);

sub showLog {
    my ($c, $mode, $log_uri) = @_;
    $mode //= "pretty";

    if ($mode eq "pretty") {
        $c->stash->{log_uri} = $log_uri;
        $c->stash->{template} = 'log.tt';
    }

    elsif ($mode eq "raw") {
        $c->res->redirect($log_uri);
    }

    elsif ($mode eq "tail") {
        my $lines = 50;
        $c->stash->{log_uri} = $log_uri . "?tail=$lines";
        $c->stash->{tail} = $lines;
        $c->stash->{template} = 'log.tt';

        my $step = $c->stash->{step};
        my $isLive = $step ? $step->busy != 0 : !$c->stash->{build}->finished;
        if ($isLive && $c->config->{'ws_endpoint'}) {
            $c->stash->{live} = 1;
        }
        if (my $ws = $c->config->{'ws_endpoint'}) {
            $c->stash->{ws_endpoint} = $ws;
        }
    }

    else {
        error($c, "Unknown log display mode '$mode'.");
    }
}

1;

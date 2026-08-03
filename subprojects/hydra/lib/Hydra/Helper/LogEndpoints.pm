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
    }

    else {
        error($c, "Unknown log display mode '$mode'.");
    }
}

1;

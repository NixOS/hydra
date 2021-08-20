package Hydra::View::NixNAR;

use strict;
use base qw/Catalyst::View/;
use Hydra::Helper::CatalystUtils;

sub process {
    my ($self, $c) = @_;

    my $storePath  = $c->stash->{storePath};
    my $numThreads = $c->config->{'compress_num_threads'};
    my $pParam     = ($numThreads > 0) ? "-p$numThreads" : "";

    $c->response->content_type('application/x-nix-archive'); # !!! check MIME type

    my $fh = IO::Handle->new();

    open $fh, "nix-store --dump '$storePath' | pixz -0 $pParam |";

    setCacheHeaders($c, 365 * 24 * 60 * 60);

    $c->response->body($fh);

    return 1;
}

1;

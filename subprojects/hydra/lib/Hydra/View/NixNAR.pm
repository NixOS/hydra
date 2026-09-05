package Hydra::View::NixNAR;

use strict;
use warnings;
use base qw/Catalyst::View/;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Nix;
use Hydra::StorePath;

sub process {
    my ($self, $c) = @_;

    my $storePath  = $c->stash->{storePath};
    my $numThreads = $c->config->{'compress_num_threads'};
    my $pParam     = ($numThreads > 0) ? "-p$numThreads" : "";

    # `nix-store --dump` is outside Hydra, so it wants the full path.
    my $fullPath = printStorePath(machineLocalStore()->storeDir, $storePath);

    $c->response->content_type('application/x-nix-archive'); # !!! check MIME type

    my $fh = IO::Handle->new();

    open($fh, "-|", "nix-store --dump '$fullPath' | pixz -0 $pParam");

    setCacheHeaders($c, 365 * 24 * 60 * 60);

    $c->response->body($fh);

    return 1;
}

1;

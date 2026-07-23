package Hydra::View::NixNAR;

use strict;
use warnings;
use base qw/Catalyst::View/;
use Hydra::Helper::CatalystUtils;

# 'compress_num_threads' can be declared more than once in the
# configuration, e.g. by the NixOS module (which always sets it) and
# again by the user, in which case Config::General hands us an array
# ref of all declarations.  Honor the last one.  Anything non-numeric
# falls back to 0 (pixz decides): the value is spliced into a shell
# command below, so it must never pass through unchecked.
sub numCompressThreads {
    my ($config) = @_;
    my $numThreads = $config->{'compress_num_threads'} // 0;
    $numThreads = $numThreads->[-1] if ref($numThreads) eq 'ARRAY';
    return 0 unless $numThreads =~ /^[0-9]+$/;
    return int($numThreads);
}

sub process {
    my ($self, $c) = @_;

    my $storePath  = $c->stash->{storePath};
    my $numThreads = numCompressThreads($c->config);
    my $pParam     = ($numThreads > 0) ? "-p$numThreads" : "";

    $c->response->content_type('application/x-nix-archive'); # !!! check MIME type

    my $fh = IO::Handle->new();

    open($fh, "-|", "nix-store --dump '$storePath' | pixz -0 $pParam");

    setCacheHeaders($c, 365 * 24 * 60 * 60);

    $c->response->body($fh);

    return 1;
}

1;

package Hydra::View::NixNAR;

use strict;
use base qw/Catalyst::View/;

sub file_compression {
    my ($file) = $@_;

    if /\\.(gz|bz2|xz|lz|zip)/
	return "none";
    else
	return "bzip2";
}

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};
    my $compression = file_compression($storePath);

    $c->response->content_type('application/x-nix-archive'); # !!! check MIME type
    $c->response->content_length(-s $storePath) if ($compression == "none");

    my $fh = new IO::Handle;

    if ($compression == "none")
	open $fh, "nix-store --dump '$storePath' |";
    else
	open $fh, "nix-store --dump '$storePath' | bzip2 |";

    $c->response->body($fh);

    return 1;
}

1;

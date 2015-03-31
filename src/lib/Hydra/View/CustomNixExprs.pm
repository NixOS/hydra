package Hydra::View::CustomNixExprs;

use strict;
use base qw/Catalyst::View/;
use IO::Compress::Bzip2 qw(bzip2);
use File::Find;
use File::Spec;
use IPC::Open2;

sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};

    my ($tarentries, $tardata);
    open2($tardata, $tarentries, "tar", "c", "-C", $storePath,
        "--null", "-T", "-", "--no-recursion", "--no-unquote",
        "--transform", "s,^,channel/,");

    sub addFile {
        return if $File::Find::name eq $storePath;
        my $rel = File::Spec->abs2rel($File::Find::name, $storePath);
        print $tarentries "$rel\0";
    }

    find({
        preprocess => sub { return sort @_ },
        wanted => \&addFile,
    }, $storePath);

    close $tarentries;

    my $bzip2data;
    bzip2 $tardata => \$bzip2data;

    $c->response->content_type('application/x-bzip2');
    $c->response->body($bzip2data);
    return 1;
}

1;

package Hydra::View::NixManifest;

use strict;
use base qw/Catalyst::View/;
use IO::Pipe;
use POSIX qw(dup2);


sub process {
    my ($self, $c) = @_;

    my @storePaths = @{$c->stash->{storePaths}};
    
    $c->response->content_type('text/x-nix-manifest');

    my @paths = split '\n', `nix-store --query --requisites @storePaths`;
    die "cannot query dependencies of path(s) @storePaths: $?" if $? != 0;

    my $manifest =
        "version {\n" .
        "  ManifestVersion: 3\n" .
        "}\n";
    
    foreach my $path (@paths) {
        my @refs = split '\n', `nix-store --query --references $path`;
        die "cannot query references of `$path': $?" if $? != 0;
        
        my $hash = `nix-store --query --hash $path`
            or die "cannot query hash of `$path': $?";
        chomp $hash;

        my $url = $c->stash->{narBase} . $path;

        my $deriver = `nix-store --query --deriver $path`
            or die "cannot query deriver of `$path': $?";
        chomp $deriver;
        
        $manifest .=
            "{\n" .
            "  StorePath: $path\n" .
            (scalar @refs > 0 ? "  References: @refs\n" : "") .
            ($deriver ne "unknown-deriver" ? "  Deriver: $deriver\n" : "") .
            "  NarURL: $url\n" .
            "  NarHash: $hash\n" .
            "}\n";
    }

    $c->response->body($manifest);

    return 1;
}

1;

package Hydra::View::NixManifest;

use strict;
use warnings;
use base qw/Catalyst::View/;
use Hydra::Helper::Nix;
use Nix::Store;


sub process {
    my ($self, $c) = @_;

    my @storePaths = @{$c->stash->{storePaths}};

    $c->response->content_type('text/x-nix-manifest');

    my @paths = computeFSClosure(0, 1, @storePaths);

    my $manifest =
        "version {\n" .
        "  ManifestVersion: 4\n" .
        "}\n";

    foreach my $path (@paths) {
        my ($deriver, $hash, $time, $narSize, $refs) = queryPathInfo($path, 1);

        # Escape the characters that are allowed to appear in a Nix
        # path name but have special meaning in a URI.
        my $escaped = $path;
        $escaped =~ s/^.*\///; # remove /nix/store/
        $escaped =~ s/\+/%2b/g;
        $escaped =~ s/\=/%3d/g;
        $escaped =~ s/\?/%3f/g;

        my $url = $c->stash->{narBase} . "/" . $escaped;

        my $system = $c->stash->{systemForPath}->{$path};

        $manifest .=
            "{\n" .
            "  StorePath: $path\n" .
            (scalar @{$refs} > 0 ? "  References: @{$refs}\n" : "") .
            (defined $deriver ? "  Deriver: $deriver\n" : "") .
            "  NarURL: $url\n" .
            "  NarHash: $hash\n" .
            ($narSize != 0 ? "  NarSize: $narSize\n" : "") .
            (defined $system ? "  System: $system\n" : "") .
            "}\n";
    }

    $c->response->body($manifest);

    return 1;
}


1;

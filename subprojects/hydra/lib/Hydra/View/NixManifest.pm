package Hydra::View::NixManifest;

use strict;
use warnings;
use base qw/Catalyst::View/;
use Hydra::Helper::Nix;
use Hydra::StorePath;
use Nix::Store;


sub process {
    my ($self, $c) = @_;

    my @storePaths = @{$c->stash->{storePaths}};
    my $storeDir = machineLocalStore()->storeDir;

    $c->response->content_type('text/x-nix-manifest');

    my @paths = machineLocalStore()->computeFSClosure(0, 1, @storePaths);

    my $manifest =
        "version {\n" .
        "  ManifestVersion: 4\n" .
        "}\n";

    foreach my $path (@paths) {
        my ($deriver, $hash, $time, $narSize, $refs) = machineLocalStore()->queryPathInfo($path, 1);

        # Escape the characters that are allowed to appear in a Nix
        # path name but have special meaning in a URI. The NAR URL names
        # the path bare, which is what a store path now stringifies to,
        # so there is no store directory left to strip.
        my $escaped = "$path";
        $escaped =~ s/\+/%2b/g;
        $escaped =~ s/\=/%3d/g;
        $escaped =~ s/\?/%3f/g;

        my $url = $c->stash->{narBase} . "/" . $escaped;

        my $system = $c->stash->{systemForPath}->{$path};

        # Unlike a narinfo, a manifest names `StorePath`, `References` and
        # `Deriver` by their full paths, so print each one.
        $manifest .=
            "{\n" .
            "  StorePath: " . printStorePath($storeDir, $path) . "\n" .
            (scalar @{$refs} > 0
                ? "  References: " . join(" ", map { printStorePath($storeDir, $_) } @{$refs}) . "\n"
                : "") .
            (defined $deriver ? "  Deriver: " . printStorePath($storeDir, $deriver) . "\n" : "") .
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

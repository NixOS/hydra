#! /var/run/current-system/sw/bin/perl -w

use strict;
use File::Path;
use File::Basename;
use Hydra::Schema;
use Hydra::Helper::Nix;

my $db = openHydraDB;

die unless defined $ENV{LOGNAME};
my $gcRootsDir = "/nix/var/nix/gcroots/per-user/$ENV{LOGNAME}/hydra-roots";


my %roots;

sub registerRoot {
    my ($path) = @_;
    print "$path\n";

    mkpath($gcRootsDir) if !-e $gcRootsDir;

    my $link = "$gcRootsDir/" . basename $path;
        
    if (!-e $link) {
        symlink($path, $link)
            or die "cannot creating symlink in $gcRootsDir to $path";
    }

    $roots{$path} = 1;
}


# Determine which builds to keep automatically.
my %pathsToKeep;

# TODO


# For finished builds, we only keep the output path, not the derivation.
foreach my $build ($db->resultset('Builds')->search({finished => 1, buildStatus => 0}, {join => 'resultInfo'})) {
    if ($build->resultInfo->keep || defined $pathsToKeep{$build->outpath}) {
        if (isValidPath($build->outpath)) {
            registerRoot $build->outpath;
        } else {
            print STDERR "warning: output ", $build->outpath, " has disappeared\n";
        }
    }
}


# For scheduled builds, we register the derivation as a GC root.
foreach my $build ($db->resultset('Builds')->search({finished => 0}, {join => 'schedulingInfo'})) {
    if (isValidPath($build->drvpath)) {
        registerRoot $build->drvpath;
    } else {
        print STDERR "warning: derivation ", $build->drvpath, " has disappeared\n";
    }
}


# Remove existing roots that are no longer wanted.  !!! racy
opendir DIR, $gcRootsDir or die;

foreach my $link (readdir DIR) {
    next if !-l "$gcRootsDir/$link";
    my $path = readlink "$gcRootsDir/$link" or die;
    if (!defined $roots{$path}) {
        print STDERR "removing root $path\n";
        unlink "$gcRootsDir/$link" or die "cannot remove $gcRootsDir/$link";
    }
}

closedir DIR;

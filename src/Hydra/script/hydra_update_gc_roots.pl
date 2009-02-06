#! /var/run/current-system/sw/bin/perl -w

use strict;
use File::Path;
use File::Basename;
use Hydra::Schema;
use Hydra::Helper::Nix;
use POSIX qw(strftime);

my $db = openHydraDB;

die unless defined $ENV{LOGNAME};
my $gcRootsDir = "/nix/var/nix/gcroots/per-user/$ENV{LOGNAME}/hydra-roots";


my %roots;

sub registerRoot {
    my ($path) = @_;
    #print "$path\n";

    mkpath($gcRootsDir) if !-e $gcRootsDir;

    my $link = "$gcRootsDir/" . basename $path;
        
    if (!-l $link) {
        symlink($path, $link)
            or die "cannot create symlink in $gcRootsDir to $path";
    }

    $roots{$path} = 1;
}


sub keepBuild {
    my ($build) = @_;
    print "keeping build ", $build->id, " (",
            strftime("%Y-%m-%d %H:%M:%S", localtime($build->timestamp)), ")\n";
    if (isValidPath($build->outpath)) {
        registerRoot $build->outpath;
    } else {
        print STDERR "warning: output ", $build->outpath, " has disappeared\n";
    }
}


# Go over all jobs in all projects.

foreach my $project ($db->resultset('Projects')->all) {

    foreach my $job ($project->builds->search({},
        {select => [{distinct => 'attrname'}], as => ['attrname']}))
    {
        print "*** looking for builds to keep in ", $project->name, ":", $job->attrname, "\n";

        # Keep the N most recent successful builds for each job and
        # platform.
        my @recentBuilds = $project->builds->search(
            { attrname => $job->attrname
            , finished => 1
            , buildStatus => 0 # == success
            },
            { join => 'resultInfo'
            , order_by => 'timestamp DESC'
            , rows => 3 # !!! should make this configurable
            });

        keepBuild $_ foreach @recentBuilds;
    }
}


# Keep all builds that have been marked as "keep".
print "*** looking for kept builds\n";
my @buildsToKeep = $db->resultset('Builds')->search({finished => 1, keep => 1}, {join => 'resultInfo'});
keepBuild $_ foreach @buildsToKeep;


# For scheduled builds, we register the derivation as a GC root.
print "*** looking for scheduled builds\n";
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

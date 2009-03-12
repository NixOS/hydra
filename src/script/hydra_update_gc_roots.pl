#! /var/run/current-system/sw/bin/perl -w

use strict;
use File::Path;
use File::Basename;
use Hydra::Schema;
use Hydra::Helper::Nix;
use POSIX qw(strftime);

my $db = openHydraDB;


my %roots;

sub registerRoot {
    my ($path) = @_;
    Hydra::Helper::Nix::registerRoot($path);
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


# Go over all projects.

foreach my $project ($db->resultset('Projects')->all) {

    # Go over all jobs in this project.

    foreach my $job ($project->builds->search({},
        {select => [{distinct => 'job'}], as => ['job']}))
    {
        print "*** looking for builds to keep in job ", $project->name, ":", $job->job, "\n";

        # Keep the N most recent successful builds for each job and
        # platform.
        my @recentBuilds = $project->builds->search(
            { job => $job->job
            , finished => 1
            , buildStatus => 0 # == success
            },
            { join => 'resultInfo'
            , order_by => 'timestamp DESC'
            , rows => 3 # !!! should make this configurable
            });
        
        keepBuild $_ foreach @recentBuilds;

    }

    # Go over all releases in this project.

    foreach my $releaseSet ($project->releasesets->all) {
        print "*** looking for builds to keep in release set ", $project->name, ":", $releaseSet->name, "\n";

        (my $primaryJob) = $releaseSet->releasesetjobs->search({isprimary => 1});
        my $jobs = [$releaseSet->releasesetjobs->all];

        # Keep all builds belonging to the most recent successful release.
        my $latest = getLatestSuccessfulRelease($project, $primaryJob, $jobs);
        if (defined $latest) {
            print "keeping latest successful release ", $latest->id, " (", $latest->get_column('releasename'), ")\n";
            my $release = getRelease($latest, $jobs);
            keepBuild $_->{build} foreach @{$release->{jobs}};
        }
    }
    
}


# Keep all builds that have been marked as "keep".
print "*** looking for kept builds\n";
my @buildsToKeep = $db->resultset('Builds')->search({finished => 1, keep => 1}, {join => 'resultInfo'});
keepBuild $_ foreach @buildsToKeep;


# For scheduled builds, we register the derivation and the output as a GC root.
print "*** looking for scheduled builds\n";
foreach my $build ($db->resultset('Builds')->search({finished => 0}, {join => 'schedulingInfo'})) {
    if (isValidPath($build->drvpath)) {
        print "keeping scheduled build ", $build->id, " (",
            strftime("%Y-%m-%d %H:%M:%S", localtime($build->timestamp)), ")\n";
        registerRoot $build->drvpath;
        registerRoot $build->outpath;
    } else {
        print STDERR "warning: derivation ", $build->drvpath, " has disappeared\n";
    }
}


# Remove existing roots that are no longer wanted.  !!! racy
print "*** removing unneeded GC roots\n";

my $gcRootsDir = getGCRootsDir;

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

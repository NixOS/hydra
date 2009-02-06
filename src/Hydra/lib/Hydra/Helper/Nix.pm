package Hydra::Helper::Nix;

use strict;
use Exporter;
use File::Basename;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    isValidPath getHydraPath getHydraDBPath openHydraDB
    getPrimaryBuildsForReleaseSet getRelease getLatestSuccessfulRelease );


sub isValidPath {
    my $path = shift;
    #$SIG{CHLD} = 'DEFAULT'; # !!! work around system() failing if SIGCHLD is ignored
    #return system("nix-store --check-validity $path 2> /dev/null") == 0;

    # This is faster than calling nix-store, but it breaks abstraction...
    return -e ("/nix/var/nix/db/info/" . basename $path);
}


sub getHydraPath {
    my $dir = $ENV{"HYDRA_DATA"};
    die "The HYDRA_DATA environment variable is not set!\n" unless defined $dir;
    die "The HYDRA_DATA directory does not exist!\n" unless -d $dir;
    return $dir;
}


sub getHydraDBPath {
    my $path = getHydraPath . '/hydra.sqlite';
    die "The Hydra database ($path) not exist!\n" unless -f $path;
    return "dbi:SQLite:$path";
}


sub openHydraDB {
    my $db = Hydra::Schema->connect(getHydraDBPath, "", "", {});
    $db->storage->dbh->do("PRAGMA synchronous = OFF;");
    return $db;
}


sub attrsToSQL {
    my ($attrs, $id) = @_;
    my @attrs = split / /, $attrs;

    my $query = "1 = 1";

    foreach my $attr (@attrs) {
        $attr =~ /^([\w-]+)=([\w-]*)$/ or die "invalid attribute in release set: $attr";
        my $name = $1;
        my $value = $2;
        # !!! Yes, this is horribly injection-prone... (though
        # name/value are filtered above).  Should use SQL::Abstract,
        # but it can't deal with subqueries.  At least we should use
        # placeholders.
        $query .= " and (select count(*) from buildinputs where build = $id and name = '$name' and value = '$value') = 1";
    }

    return $query;
}


sub getPrimaryBuildsForReleaseSet {
    my ($project, $primaryJob) = @_;
    my @primaryBuilds = $project->builds->search(
        { attrname => $primaryJob->job, finished => 1 },
        { join => 'resultInfo', order_by => "timestamp DESC"
        , '+select' => ["resultInfo.releasename"], '+as' => ["releasename"]
        , where => \ attrsToSQL($primaryJob->attrs, "me.id")
        });
    return @primaryBuilds;
}


sub getRelease {
    my ($primaryBuild, $jobs) = @_;
    
    my @jobs = ();

    my $status = 0; # = okay

    # The timestamp of the release is the highest timestamp of all
    # constitutent builds.
    my $timestamp = 0;
        
    foreach my $job (@{$jobs}) {
        my $thisBuild;

        if ($job->isprimary) {
            $thisBuild = $primaryBuild;
        } else {
            # Find a build of this job that had the primary build
            # as input.  If there are multiple, prefer successful
            # ones, and then oldest.  !!! order_by buildstatus is hacky
            ($thisBuild) = $primaryBuild->dependentBuilds->search(
                { attrname => $job->job, finished => 1 },
                { join => 'resultInfo', rows => 1
                , order_by => ["buildstatus", "timestamp"]
                , where => \ attrsToSQL($job->attrs, "build.id")
                });
        }

        if ($job->mayfail != 1) {
            if (!defined $thisBuild) {
                $status = 2 if $status == 0; # = unfinished
            } elsif ($thisBuild->resultInfo->buildstatus != 0) {
                $status = 1; # = failed
            }
        }

        $timestamp = $thisBuild->timestamp
            if defined $thisBuild && $thisBuild->timestamp > $timestamp;

        push @jobs, { build => $thisBuild, job => $job };
    }

    return
        { id => $primaryBuild->id
        , releasename => $primaryBuild->get_column('releasename')
        , jobs => [@jobs]
        , status => $status
        , timestamp => $timestamp
        };
}


sub getLatestSuccessfulRelease {
    my ($project, $primaryJob, $jobs) = @_;
    my $latest;
    foreach my $build (getPrimaryBuildsForReleaseSet($project, $primaryJob)) {
        return $build if getRelease($build, $jobs)->{status} == 0;
    }
    return undef;
    
}

    
1;

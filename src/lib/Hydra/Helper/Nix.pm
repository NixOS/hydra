package Hydra::Helper::Nix;

use strict;
use Exporter;
use File::Path;
use File::Basename;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    isValidPath queryPathInfo
    getHydraPath getHydraDBPath openHydraDB txn_do
    registerRoot getGCRootsDir gcRootFor
    getPrimaryBuildsForReleaseSet getRelease getLatestSuccessfulRelease );


sub isValidPath {
    my $path = shift;
    #$SIG{CHLD} = 'DEFAULT'; # !!! work around system() failing if SIGCHLD is ignored
    #return system("nix-store --check-validity $path 2> /dev/null") == 0;

    # This is faster than calling nix-store, but it breaks abstraction...
    return -e ("/nix/var/nix/db/info/" . basename $path);
}


sub queryPathInfo {
    my $path = shift;

    # !!! like above, this breaks abstraction.  What we really need is
    # Perl bindings for libstore :-)

    open FH, "</nix/var/nix/db/info/" . basename $path
        or die "cannot open info file for $path";

    my $hash;
    my $deriver;
    my @refs = ();

    while (<FH>) {
        if (/^Hash: (\S+)$/) {
            $hash = $1;
        }
        elsif (/^Deriver: (\S+)$/) {
            $deriver = $1;
        }
        elsif (/^References: (.*)$/) {
            @refs = split / /, $1;
        }
    }

    close FH;

    die "path $path does not have a hash" unless defined $hash;

    return ($hash, $deriver, \@refs);
}


sub getHydraPath {
    my $dir = $ENV{"HYDRA_DATA"};
    die "The HYDRA_DATA environment variable is not set!\n" unless defined $dir;
    die "The HYDRA_DATA directory does not exist!\n" unless -d $dir;
    return $dir;
}


sub getHydraDBPath {
    my $db = $ENV{"HYDRA_DBI"};
    if ( defined $db ) {
      return $db ;
    }
    else {
        my $path = getHydraPath . '/hydra.sqlite';
        die "The Hydra database ($path) not exist!\n" unless -f $path;
        return "dbi:SQLite:$path";
    }
}


sub openHydraDB {
    my $db = Hydra::Schema->connect(getHydraDBPath, "", "", {});
    $db->storage->dbh->do("PRAGMA synchronous = OFF;")
        if defined $ENV{'HYDRA_NO_FSYNC'};
    return $db;
}


# Awful hack to handle timeouts in SQLite: just retry the transaction.
# DBD::SQLite *has* a 30 second retry window, but apparently it
# doesn't work.
sub txn_do {
    my ($db, $coderef) = @_;
    while (1) {
        eval {
            $db->txn_do($coderef);
        };
        last if !$@;
        die $@ unless $@ =~ "database is locked";
    }
}


sub getGCRootsDir {
    die unless defined $ENV{LOGNAME};
    my $dir = "/nix/var/nix/gcroots/per-user/$ENV{LOGNAME}/hydra-roots";
    mkpath $dir if !-e $dir;
    return $dir;
}


sub gcRootFor {
    my ($path) = @_;
    return getGCRootsDir . "/" . basename $path;
}


sub registerRoot {
    my ($path) = @_;
    
    my $link = gcRootFor $path;
    
    if (!-l $link) {
        symlink($path, $link)
            or die "cannot create GC root `$link' to `$path'";
    }
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
        $query .= " and exists (select 1 from buildinputs where build = $id and name = '$name' and value = '$value')";
    }

    return $query;
}


sub getPrimaryBuildsForReleaseSet {
    my ($project, $primaryJob) = @_;
    my @primaryBuilds = $project->builds->search(
        { jobset => $primaryJob->get_column('jobset'), job => $primaryJob->get_column('job'), finished => 1 },
        { join => 'resultInfo', order_by => "timestamp DESC"
        , '+select' => ["resultInfo.releasename", "resultInfo.buildstatus"]
        , '+as' => ["releasename", "buildstatus"]
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
                { project => $job->get_column('project'), jobset => $job->get_column('jobset')
                , job => $job->get_column('job'), finished => 1 },
                { join => 'resultInfo', rows => 1
                , order_by => ["buildstatus", "timestamp"]
                , where => \ attrsToSQL($job->attrs, "build.id")
                , '+select' => ["resultInfo.buildstatus"], '+as' => ["buildstatus"]
                });
        }

        if ($job->mayfail != 1) {
            if (!defined $thisBuild) {
                $status = 2 if $status == 0; # = unfinished
            } elsif ($thisBuild->get_column('buildstatus') != 0) {
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

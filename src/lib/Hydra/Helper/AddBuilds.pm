package Hydra::Helper::AddBuilds;

use strict;
use POSIX qw(strftime);
use Hydra::Helper::Nix;

our @ISA = qw(Exporter);
our @EXPORT = qw(fetchInput);


sub getStorePathHash {
    my ($storePath) = @_;
    my $hash = `nix-store --query --hash $storePath`
        or die "cannot get hash of $storePath";
    chomp $hash;
    die unless $hash =~ /^sha256:(.*)$/;
    $hash = $1;
    $hash = `nix-hash --to-base16 --type sha256 $hash`
        or die "cannot convert hash";
    chomp $hash;
    return $hash;    
}


sub parseJobName {
    # Parse a job specification of the form `<project>:<jobset>:<job>
    # [attrs]'.  The project, jobset and attrs may be omitted.  The
    # attrs have the form `name = "value"'.
    my ($s) = @_;
    our $key;
    our %attrs = ();
    # hm, maybe I should stop programming Perl before it's too late...
    $s =~ / ^ (?: (?: ([\w\-]+) : )? ([\w\-]+) : )? ([\w\-]+) \s*
            (\[ \s* (
              ([\w]+) (?{ $key = $^N; }) \s* = \s* \"
              ([\w\-]+) (?{ $attrs{$key} = $^N; }) \"
            \s* )* \])? $
          /x
        or die "invalid job specifier `$s'";
    return ($1, $2, $3, \%attrs);
}


sub attrsToSQL {
    my ($attrs, $id) = @_;

    my $query = "1 = 1";

    foreach my $name (keys %{$attrs}) {
        my $value = $attrs->{$name};
        $name =~ /^[\w\-]+$/ or die;
        $value =~ /^[\w\-]+$/ or die;
        # !!! Yes, this is horribly injection-prone... (though
        # name/value are filtered above).  Should use SQL::Abstract,
        # but it can't deal with subqueries.  At least we should use
        # placeholders.
        $query .= " and exists (select 1 from buildinputs where build = $id and name = '$name' and value = '$value')";
    }

    return $query;
}


sub fetchInput {
    my ($db, $project, $jobset, $name, $type, $value) = @_;

    if ($type eq "path") {
        my $uri = $value;

        my $timestamp = time;
        my $sha256;
        my $storePath;

        # Some simple caching: don't check a path more than once every N seconds.
        (my $cachedInput) = $db->resultset('CachedPathInputs')->search(
            {srcpath => $uri, lastseen => {">", $timestamp - 60}},
            {rows => 1, order_by => "lastseen DESC"});

        if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
            $storePath = $cachedInput->storepath;
            $sha256 = $cachedInput->sha256hash;
            $timestamp = $cachedInput->timestamp;
        } else {

            print STDERR "copying input ", $name, " from $uri\n";
            $storePath = `nix-store --add "$uri"`
                or die "Cannot copy path $uri to the Nix store.\n";
            chomp $storePath;

            $sha256 = getStorePathHash $storePath;

            ($cachedInput) = $db->resultset('CachedPathInputs')->search(
                {srcpath => $uri, sha256hash => $sha256});

            # Path inputs don't have a natural notion of a "revision",
            # so we simulate it by using the timestamp that we first
            # saw this path have this SHA-256 hash.  So if the
            # contents of the path changes, we get a new "revision",
            # but if it doesn't change (or changes back), we don't get
            # a new "revision".
            if (!defined $cachedInput) {
                txn_do($db, sub {
                    $db->resultset('CachedPathInputs')->create(
                        { srcpath => $uri
                        , timestamp => $timestamp
                        , lastseen => $timestamp
                        , sha256hash => $sha256
                        , storepath => $storePath
                        });
                });
            } else {
                $timestamp = $cachedInput->timestamp;
                txn_do($db, sub {
                    $cachedInput->update({lastseen => time});
                });
            }
        }

        return
            { type => $type
            , uri => $uri
            , storePath => $storePath
            , sha256hash => $sha256
            , revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp)
            };
    }

    elsif ($type eq "svn") {
        my $uri = $value;

        my $sha256;
        my $storePath;

        # First figure out the last-modified revision of the URI.
        my @cmd = (["svn", "ls", "-v", "--depth", "empty", $uri],
                   "|", ["sed", 's/^ *\([0-9]*\).*/\1/']);
        my $stdout; my $stderr;
        die "Cannot get head revision of Subversion repository at `$uri':\n$stderr"
            unless IPC::Run::run(@cmd, \$stdout, \$stderr);
        my $revision = $stdout; chomp $revision;
        die unless $revision =~ /^\d+$/;

        (my $cachedInput) = $db->resultset('CachedSubversionInputs')->search(
            {uri => $uri, revision => $revision});

        if (defined $cachedInput && isValidPath($cachedInput->storepath)) {
            $storePath = $cachedInput->storepath;
            $sha256 = $cachedInput->sha256hash;
        } else {
            
            # Then download this revision into the store.
            print STDERR "checking out Subversion input ", $name, " from $uri revision $revision\n";
            $ENV{"NIX_HASH_ALGO"} = "sha256";
            $ENV{"PRINT_PATH"} = "1";
            (my $res, $stdout, $stderr) = captureStdoutStderr(
                "nix-prefetch-svn", $uri, $revision);
            die "Cannot check out Subversion repository `$uri':\n$stderr" unless $res;

            ($sha256, $storePath) = split ' ', $stdout;

            txn_do($db, sub {
                $db->resultset('CachedSubversionInputs')->create(
                    { uri => $uri
                    , revision => $revision
                    , sha256hash => $sha256
                    , storepath => $storePath
                    });
            });
        }

        return 
            { type => $type
            , uri => $uri
            , storePath => $storePath
            , sha256hash => $sha256
            , revision => $revision
            };
    }

    elsif ($type eq "build") {
        my ($projectName, $jobsetName, $jobName, $attrs) = parseJobName($value);
        $projectName ||= $project->name;
        $jobsetName ||= $jobset->name;

        # Pick the most recent successful build of the specified job.
        (my $prevBuild) = $db->resultset('Builds')->search(
            { finished => 1, project => $projectName, jobset => $jobsetName
            , job => $jobName, buildStatus => 0 },
            { join => 'resultInfo', order_by => "me.id DESC", rows => 1
            , where => \ attrsToSQL($attrs, "me.id") });

        if (!defined $prevBuild || !isValidPath($prevBuild->outpath)) {
            print STDERR "input `", $name, "': no previous build available\n";
            return undef;
        }

        #print STDERR "input `", $name, "': using build ", $prevBuild->id, "\n";

        my $pkgNameRE = "(?:(?:[A-Za-z0-9]|(?:-[^0-9]))+)";
        my $versionRE = "(?:[A-Za-z0-9\.\-]+)";

        my $relName = ($prevBuild->resultInfo->releasename or $prevBuild->nixname);
        my $version = $2 if $relName =~ /^($pkgNameRE)-($versionRE)$/;
        
        return 
            { type => "build"
            , storePath => $prevBuild->outpath
            , id => $prevBuild->id
            , version => $version
            };
    }
    
    elsif ($type eq "string") {
        die unless defined $value;
        return {type => $type, value => $value};
    }
    
    elsif ($type eq "boolean") {
        die unless defined $value && ($value eq "true" || $value eq "false");
        return {type => $type, value => $value};
    }
    
    else {
        die "Input `" . $name . "' has unknown type `$type'.";
    }
}

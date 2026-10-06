package Hydra::StorePath;

use strict;
use warnings;
use Exporter;
use Nix::StorePath;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    parseStorePath
    parseRowStorePath
    printStorePath
    parseRelativeStorePath
    printRelativeStorePath
    storePathForms
    );

# The store path type itself is `Nix::StorePath`, next to the bindings that
# speak it. What lives here is the store *directory*, which is Hydra's
# business rather than the bindings': these functions are the only place it is
# put on or taken off. Strip as early as a path is read, print only where one
# is rendered or handed to something outside Hydra.
#
# The store directory is always passed in rather than read from a global, so
# that it comes from the store in hand -- for database columns, the schema's
# -- the way the Rust side takes a `StoreDir`.

sub _stripStoreDir {
    my ($storeDir, $path) = @_;
    die "path '$path' is not in the Nix store '$storeDir'\n"
        unless substr($path, 0, length($storeDir) + 1) eq "$storeDir/";
    return substr($path, length($storeDir) + 1);
}

sub parseStorePath {
    my ($storeDir, $path) = @_;
    my $rest = _stripStoreDir($storeDir, $path);
    die "path '$path' names something underneath a store path, not a store path itself\n"
        if index($rest, "/") != -1;
    return Nix::StorePath->new($rest);
}

# Parse a store path straight out of a column, in whichever of the two formats
# the row holds it: a converted row has the basename, one that
# `hydra-backfill-store-dirs` has not reached yet has the full path. Telling
# them apart needs no second column, a full path always having a slash and a
# basename never.
#
# `Hydra::Component::InflateStorePath` is the usual way to get here. This is
# for the reads that go around it -- raw SQL that aggregates a path column, so
# never sees an inflator.
sub parseRowStorePath {
    my ($storeDir, $path) = @_;
    return Nix::StorePath->new($path) unless index($path, "/") != -1;
    return parseStorePath($storeDir, $path);
}

sub printStorePath {
    my ($storeDir, $storePath) = @_;
    return "$storeDir/" . $storePath->to_string;
}



# A path *underneath* a store path, e.g. a build product's
# `/nix/store/<hash>-<name>/share/doc/index.html`. It is two things, and is
# carried as two: a `Nix::StorePath` and the sub-path below it, which is "" when
# the path names the store path exactly.

# Split a full such path into that pair. Only unconverted `BuildProducts` rows
# still need this, the column having become two columns; see
# `Hydra::Component::InflateStorePath`.
sub parseRelativeStorePath {
    my ($storeDir, $path) = @_;
    my ($base, $subPath) = split(m{/}, _stripStoreDir($storeDir, $path), 2);
    return (Nix::StorePath->new($base), $subPath // "");
}

sub printRelativeStorePath {
    my ($storeDir, $storePath, $subPath) = @_;
    my $path = printStorePath($storeDir, $storePath);
    return $subPath eq "" ? $path : $path . "/" . $subPath;
}

# Both spellings a store-path column may hold, for use with `-in`.
#
# Until `hydra-backfill-store-dirs` has been all the way through, a column
# holds the basename in converted rows and the full path in the rest, so a
# lookup keyed on a path has to match either. `-in` keeps the existing indexes
# serving the query, where an `OR` of two comparisons might not.
#
# Callers hold a `Nix::StorePath` and so know only the basename; this is where
# the other form gets spelled out. That it has to be spelled out at all is
# because `search` conditions are never deflated.
sub storePathForms {
    my ($storeDir, $storePath) = @_;
    return [$storePath->to_string, printStorePath($storeDir, $storePath)];
}

1;

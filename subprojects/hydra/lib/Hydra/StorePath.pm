package Hydra::StorePath;

use strict;
use warnings;
use Exporter;
use Nix::StorePath;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    parseStorePath
    printStorePath
    parseRelativeStorePath
    printRelativeStorePath
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

sub printStorePath {
    my ($storeDir, $storePath) = @_;
    return "$storeDir/" . $storePath->to_string;
}


# A path *underneath* a store path, e.g. a build product's
# `/nix/store/<hash>-<name>/share/doc/index.html`, split the way the Rust
# `RelativeStorePath` splits it: a `Nix::StorePath` and the remainder, which is
# "" when the path names a store path exactly.
package Hydra::RelativeStorePath;

use strict;
use warnings;

use overload
    '""' => sub { $_[0]->to_string },
    fallback => 1;

sub new {
    my ($class, $basePath, $relativePath) = @_;
    return bless { basePath => $basePath, relativePath => $relativePath }, $class;
}

sub basePath { return $_[0]->{basePath} }

sub relativePath { return $_[0]->{relativePath} }

sub to_string {
    my ($self) = @_;
    return $self->{relativePath} eq ""
        ? $self->{basePath}->to_string
        : $self->{basePath}->to_string . "/" . $self->{relativePath};
}

package Hydra::StorePath;

sub parseRelativeStorePath {
    my ($storeDir, $path) = @_;
    my ($base, $relative) = split("/", _stripStoreDir($storeDir, $path), 2);
    return Hydra::RelativeStorePath->new(
        Nix::StorePath->new($base), $relative // "");
}

sub printRelativeStorePath {
    my ($storeDir, $split) = @_;
    my $path = printStorePath($storeDir, $split->basePath);
    return $split->relativePath eq "" ? $path : $path . "/" . $split->relativePath;
}

1;

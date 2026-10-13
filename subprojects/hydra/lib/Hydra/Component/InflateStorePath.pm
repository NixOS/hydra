package Hydra::Component::InflateStorePath;

use strict;
use warnings;
use base 'DBIx::Class';
use Hydra::StorePath;

# Store-path columns hold the bare `<hash>-<name>`, with the store they live in
# named once per row by the `storeDir` column. Everything above the database
# deals in `Nix::StorePath`, and this component is the boundary: it is where a
# column becomes one, and where `storeDir` gets filled in on the way back.
#
# Rows written before `hydra-backfill-store-dirs` reached them still hold a
# full path and a null `storeDir`. Reading has to cope with both for as long as
# the backfill takes. Telling them apart needs no second column, because a full
# path always contains a slash and a basename never does -- which is why a
# `columns => [...]` fetch naming only the path column still works, and why
# nothing here has to care whether `storeDir` was even selected.
sub _inflate {
    my ($value, $result) = @_;
    return parseRowStorePath($result->result_source->schema->storeDir, $value);
}

# Writes are always in the new format, so the set of unconverted rows only ever
# shrinks. The store directory is a property of the whole row rather than of
# any one column, so it is filled in here instead of by every caller.
sub insert {
    my $self = shift;
    $self->set_column(storedir => $self->result_source->schema->storeDir)
        unless defined $self->get_column("storedir");
    return $self->next::method(@_);
}

# Register columns holding a single store path, e.g.
#
#     __PACKAGE__->inflate_store_paths(qw/drvpath/);
sub inflate_store_paths {
    my ($class, @columns) = @_;
    for my $column (@columns) {
        $class->inflate_column($column, {
            # The result object is the second argument; it is how the store
            # directory is reached without consulting a global.
            inflate => \&_inflate,
            deflate => sub { $_[0]->to_string },
        });
    }
}

# Register columns that use the empty string, rather than NULL, to mean "no
# store path". JobsetEvalInputs.path does, for inputs that have none -- a hack
# its writer still flags as one. NULL is what that should be, the column being
# nullable already; tolerating "" here is what lets these columns be inflated
# without first migrating the existing rows.
#
# Both spellings read back as undef, and writing undef stores NULL, since
# DBIx::Class only puts a value through a deflator when it is a reference. So
# new rows drift towards NULL of their own accord, which is the direction we
# want; a migration would only be needed to finish the job.
sub inflate_optional_store_paths {
    my ($class, @columns) = @_;
    for my $column (@columns) {
        $class->inflate_column($column, {
            inflate => sub {
                return undef if $_[0] eq "";
                return _inflate(@_);
            },
            deflate => sub { $_[0]->to_string },
        });
    }
}

# Register the pair of columns holding a path *underneath* a store path, and
# name an accessor for each half:
#
#     __PACKAGE__->inflate_relative_store_path(
#         "path", "subpath", "storePath", "subPath");
#
# `BuildProducts.path` is the only one. It takes two columns where every other
# store-path column takes one because it names two things, and this is the
# migration that gives it the second: before it, the store path and the
# sub-path below it were a single string that callers had to take apart.
#
# An unconverted row is still that single string, with nothing in the sub-path
# column, so until the backfill has been through these have to put it back
# together themselves. The discriminator is the same as everywhere else: the
# store path in a converted row has no slash in it.
sub inflate_relative_store_path {
    my ($class, $pathColumn, $subPathColumn, $storePathAccessor, $subPathAccessor) = @_;
    my $split = sub {
        my ($self) = @_;
        my $path = $self->get_column($pathColumn);
        return () unless defined $path;
        my $subPath = $self->get_column($subPathColumn);
        return (Nix::StorePath->new($path), $subPath) if defined $subPath;
        return parseRelativeStorePath($self->result_source->schema->storeDir, $path);
    };
    no strict 'refs';
    *{"${class}::${storePathAccessor}"} = sub { ($split->($_[0]))[0] };
    *{"${class}::${subPathAccessor}"}   = sub { ($split->($_[0]))[1] };
}

1;

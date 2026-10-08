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
# Nothing here reads `storeDir`: the column value is the store path, whole. So
# a `columns => [...]` fetch naming only the path column is enough, and none of
# these accessors depend on `storeDir` having been selected.
sub _inflate {
    return Nix::StorePath->new($_[0]);
}

# The store directory is a property of the whole row rather than of any one
# column, so it is filled in here instead of by every caller.
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
# store-path column takes one because it names two things: a store path, and
# the sub-path below it.
sub inflate_relative_store_path {
    my ($class, $pathColumn, $subPathColumn, $storePathAccessor, $subPathAccessor) = @_;
    $class->inflate_store_paths($pathColumn);
    no strict 'refs';
    *{"${class}::${storePathAccessor}"} = sub { $_[0]->$pathColumn };
    *{"${class}::${subPathAccessor}"}   = sub { $_[0]->$subPathColumn };
}

1;

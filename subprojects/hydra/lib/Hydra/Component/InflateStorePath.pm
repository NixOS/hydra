package Hydra::Component::InflateStorePath;

use strict;
use warnings;
use base 'DBIx::Class';
use Hydra::StorePath;

# The database stores full paths, but everything above it should be dealing in
# store paths proper. This component is where that conversion happens, so the
# store directory comes off the moment a row is read and goes back on only
# when one is written.

# Register columns holding a single store path, e.g.
#
#     __PACKAGE__->inflate_store_paths(qw/drvpath/);
sub inflate_store_paths {
    my ($class, @columns) = @_;
    for my $column (@columns) {
        $class->inflate_column($column, {
            # The result object is the second argument; it is how the store
            # directory is reached without consulting a global.
            inflate => sub { parseStorePath($_[1]->result_source->schema->storeDir, $_[0]) },
            deflate => sub { printStorePath($_[1]->result_source->schema->storeDir, $_[0]) },
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
                return parseStorePath($_[1]->result_source->schema->storeDir, $_[0]);
            },
            deflate => sub { printStorePath($_[1]->result_source->schema->storeDir, $_[0]) },
        });
    }
}

# Register a column that holds a relative store path, naming an accessor for
# each half:
#
#     __PACKAGE__->inflate_relative_store_path("path", "storePath", "subPath");
#
# The accessors are the point. This column wants to be two columns, and when a
# migration eventually makes it two, these keep working unchanged and no caller
# has to be touched.
sub inflate_relative_store_path {
    my ($class, $column, $baseAccessor, $relativeAccessor) = @_;
    $class->inflate_column($column, {
        inflate => sub { parseRelativeStorePath($_[1]->result_source->schema->storeDir, $_[0]) },
        deflate => sub { printRelativeStorePath($_[1]->result_source->schema->storeDir, $_[0]) },
    });
    no strict 'refs';
    *{"${class}::${baseAccessor}"} = sub {
        my $split = $_[0]->$column;
        return defined $split ? $split->basePath : undef;
    };
    *{"${class}::${relativeAccessor}"} = sub {
        my $split = $_[0]->$column;
        return defined $split ? $split->relativePath : undef;
    };
}

1;

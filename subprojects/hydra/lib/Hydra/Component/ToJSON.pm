use utf8;
package Hydra::Component::ToJSON;

use strict;
use warnings;

use base 'DBIx::Class';
use JSON::MaybeXS;
use Hydra::StorePath;

sub TO_JSON {
    my $self = shift;

    if ($self->can("as_json")) {
        return $self->as_json();
    }

    my $hint = $self->json_hint;

    my %json = ();

    # `get_column`, not the accessor: the raw database value, bypassing
    # inflation. Fine for columns that are not store paths.
    foreach my $column (@{$hint->{columns}}) {
        $json{$column} = $self->get_column($column);
    }

    # Store-path columns, which this API has always spelled as full paths and
    # has to go on spelling that way. The raw value will not do for them: it
    # is the basename, or -- until `hydra-backfill-store-dirs` has been all
    # the way through -- whichever of the two formats the row happens to
    # hold. Going through the inflated accessor is what makes the answer the
    # same either way.
    my $storeDir = $self->result_source->schema->storeDir;
    foreach my $column (@{$hint->{store_path_columns}}) {
        my $storePath = $self->$column;
        $json{$column} = defined $storePath
            ? Hydra::StorePath::printStorePath($storeDir, $storePath)
            : undef;
    }

    # The same, for a path *underneath* a store path, which the database keeps
    # as two columns but this API has always served as one string.
    foreach my $column (keys %{$hint->{relative_store_path_columns}}) {
        my ($storePathAccessor, $subPathAccessor) =
            @{$hint->{relative_store_path_columns}->{$column}};
        my $storePath = $self->$storePathAccessor;
        $json{$column} = defined $storePath
            ? Hydra::StorePath::printRelativeStorePath(
                $storeDir, $storePath, $self->$subPathAccessor)
            : undef;
    }

    foreach my $column (@{$hint->{string_columns}}) {
      $json{$column} = $self->get_column($column) // "";
    }

    foreach my $column (@{$hint->{boolean_columns}}) {
        $json{$column} = $self->get_column($column) ? JSON::MaybeXS::true : JSON::MaybeXS::false;
    }

    foreach my $relname (keys %{$hint->{relations}}) {
        my $key = $hint->{relations}->{$relname};
        $json{$relname} = [ map { $_->$key } $self->$relname ];
    }

    foreach my $relname (keys %{$hint->{eager_relations}}) {
        my $key = $hint->{eager_relations}->{$relname};
        $json{$relname} = { map { $_->$key => $_ } $self->$relname };
    }

    return \%json;
}

1;

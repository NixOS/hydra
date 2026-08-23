use utf8;
package Hydra::Component::ToJSON;

use strict;
use warnings;

use base 'DBIx::Class';
use JSON::MaybeXS;

sub TO_JSON {
    my $self = shift;

    if ($self->can("as_json")) {
        return $self->as_json();
    }

    my $hint = $self->json_hint;

    my %json = ();

    # `get_column`, not the accessor, and deliberately so: it gives the raw
    # database value, bypassing inflation. That is what keeps store-path
    # columns in this API spelled as full paths, which is what it has always
    # served. Reaching for the accessor here would quietly start emitting
    # bare store paths instead.
    foreach my $column (@{$hint->{columns}}) {
        $json{$column} = $self->get_column($column);
    }

    foreach my $column (@{$hint->{string_columns}}) {
      $json{$column} = $self->get_column($column) // "";
    }

    foreach my $column (@{$hint->{boolean_columns}}) {
        $json{$column} = $self->get_column($column) ? JSON::MaybeXS::true : JSON::MaybeXS::false;
    }

    # A relation is normally emitted under its own name, as
    # `relname => column`. Passing `relname => { via => ..., key => ... }`
    # instead reads a differently-named relation, for when the JSON field
    # is named for its meaning rather than for the accessor behind it.
    foreach my $relname (keys %{$hint->{relations}}) {
        my $spec = $hint->{relations}->{$relname};
        my ($key, $via) = ref $spec eq 'HASH'
            ? ($spec->{key}, $spec->{via})
            : ($spec, $relname);
        $json{$relname} = [ map { $_->$key } $self->$via ];
    }

    foreach my $relname (keys %{$hint->{eager_relations}}) {
        my $key = $hint->{eager_relations}->{$relname};
        $json{$relname} = { map { $_->$key => $_ } $self->$relname };
    }

    return \%json;
}

1;

use utf8;
package Hydra::Component::ToJSON;

use strict;
use warnings;

use base 'DBIx::Class';

sub TO_JSON {
    my $self = shift;

    my $hint = $self->json_hint;

    my %json = ();

    foreach my $column (@{$hint->{columns}}) {
        $json{$column} = $self->get_column($column);
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

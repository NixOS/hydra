use utf8;
package Hydra::Component::ToJSON;

use strict;
use warnings;

use base 'DBIx::Class';

sub TO_JSON {
    my $self = shift;
    my $json = { $self->get_columns };
    my $rs = $self->result_source;
    my @relnames = $rs->relationships;
    RELLOOP: foreach my $relname (@relnames) {
        my $relinfo = $rs->relationship_info($relname);
        next unless defined $relinfo->{attrs}->{accessor};
        my $accessor = $relinfo->{attrs}->{accessor};
        if ($accessor eq "single" and exists $self->{_relationship_data}{$relname}) {
            $json->{$relname} = $self->$relname->TO_JSON;
        } else {
            unless (defined $self->{related_resultsets}{$relname}) {
                my $cond = $relinfo->{cond};
                if (ref $cond eq 'HASH') {
                    foreach my $k (keys %{$cond}) {
                        my $v = $cond->{$k};
                        $v =~ s/^self\.//;
                        next RELLOOP unless $self->has_column_loaded($v);
                    }
                } #!!! TODO: Handle ARRAY conditions
            }
            if (defined $self->related_resultset($relname)->get_cache) {
                if ($accessor eq "multi") {
                    $json->{$relname} = [ map { $_->TO_JSON } $self->$relname ];
                } else {
                    $json->{$relname} = $self->$relname->TO_JSON;
                }
            }
        }
    }
    return $json;
}

1;

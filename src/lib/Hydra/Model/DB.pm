package Hydra::Model::DB;

use strict;
use base 'Catalyst::Model::DBIC::Schema';

sub getHydraPath {
    my $dir = $ENV{"HYDRA_DATA"} || "/var/lib/hydra";
    die "The HYDRA_DATA directory ($dir) does not exist!\n" unless -d $dir;
    return $dir;
}

sub getHydraDBPath {
    my $db = $ENV{"HYDRA_DBI"};
    return $db if defined $db;
    my $path = getHydraPath . '/hydra.sqlite';
    #warn "The Hydra database ($path) does not exist!\n" unless -f $path;
    return "dbi:SQLite:$path";
}

__PACKAGE__->config(
    schema_class => 'Hydra::Schema',
    connect_info => {
        dsn => getHydraDBPath,
        pg_server_prepare => 0,
    },
);

=head1 NAME

Hydra::Model::DB - Catalyst DBIC Schema Model
=head1 SYNOPSIS

See L<Hydra>

=head1 DESCRIPTION

L<Catalyst::Model::DBIC::Schema> Model using schema L<Hydra::Schema>

=head1 AUTHOR

Eelco Dolstra

=head1 LICENSE

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;

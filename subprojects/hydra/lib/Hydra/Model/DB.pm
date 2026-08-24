package Hydra::Model::DB;

use strict;
use warnings;
use base 'Catalyst::Model::DBIC::Schema';
use URI::db;

sub getHydraPath {
    my $dir = $ENV{"HYDRA_DATA"} || "/var/lib/hydra";
    die "The HYDRA_DATA directory ($dir) does not exist!\n" unless -d $dir;
    return $dir;
}

# Connection info derived from the HYDRA_DATABASE_URL environment
# variable, a `postgres://` URL as understood by libpq (and by the Rust
# services, which read the same variable). Converted to a DBI DSN with
# URI::db; user and password are not part of the DSN and must be passed
# as separate connect arguments.
sub getHydraConnectInfo {
    my $url = $ENV{"HYDRA_DATABASE_URL"} || "postgres:///hydra";
    my $uri = URI::db->new("db:$url");
    die "\$HYDRA_DATABASE_URL does not denote a PostgreSQL database\n"
        unless ($uri->canonical_engine // "") eq "pg";
    return (
        dsn => $uri->dbi_dsn,
        user => scalar $uri->user,
        password => scalar $uri->password,
    );
}

__PACKAGE__->config(
    schema_class => 'Hydra::Schema',
    connect_info => {
        getHydraConnectInfo()
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

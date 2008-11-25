package Hydra::Model::DB;

use strict;
use base 'Catalyst::Model::DBIC::Schema';

__PACKAGE__->config(
    schema_class => 'Hydra::Schema',
    connect_info => [
        'dbi:SQLite:../hydra.sqlite',
        
    ],
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

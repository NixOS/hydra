package Hydra::Component::InflateExternalLink;

use strict;
use warnings;
use base 'DBIx::Class';
use Hydra::ExternalLink;

# Parse link columns into `Hydra::ExternalLink`s as rows are read. Either kind
# writes back as its `text`, so a rejected value round-trips unchanged.
#
# Register columns with, e.g.
#
#     __PACKAGE__->inflate_external_links(qw/homepage/);
sub inflate_external_links {
    my ($class, @columns) = @_;
    for my $column (@columns) {
        $class->inflate_column($column, {
            inflate => sub { Hydra::ExternalLink->parse($_[0]) },
            deflate => sub { $_[0]->text },
        });
    }
}

1;

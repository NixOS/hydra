package Hydra::ExternalLink;

use strict;
use warnings;
use URI;

# A user-supplied link to elsewhere on the web, such as a homepage. Only
# http(s) URLs are accepted, since other schemes such as `javascript:` can run
# script when clicked.
#
# A sum type, as two subclasses:
#
# - `Accepted` holds the canonical `URI`;
#
# - `Rejected` holds the string as given, to show but never link to.
#
# Both have `uri` (undef when rejected) and `text`. Neither stringifies, so a
# rejected link cannot reach an `href` by interpolation.

# Returns undef for an empty string.
sub parse {
    my ($class, $s) = @_;
    return undef unless defined $s;
    $s =~ s/^\s+|\s+$//g;
    return undef if $s eq "";
    my $uri = URI->new($s)->canonical;
    my $scheme = $uri->scheme // "";
    return $scheme eq "http" || $scheme eq "https"
        ? Hydra::ExternalLink::Accepted->new($uri)
        : Hydra::ExternalLink::Rejected->new($s);
}

sub text { return $_[0]->{text} }

package Hydra::ExternalLink::Accepted;

use strict;
use warnings;
use parent -norequire, 'Hydra::ExternalLink';

sub new {
    my ($class, $uri) = @_;
    return bless { uri => $uri, text => $uri->as_string }, $class;
}

sub uri { return $_[0]->{uri} }

package Hydra::ExternalLink::Rejected;

use strict;
use warnings;
use parent -norequire, 'Hydra::ExternalLink';

sub new {
    my ($class, $text) = @_;
    return bless { text => $text }, $class;
}

sub uri { return undef }

1;

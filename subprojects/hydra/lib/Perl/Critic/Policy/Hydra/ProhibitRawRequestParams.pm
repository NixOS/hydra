package Perl::Critic::Policy::Hydra::ProhibitRawRequestParams;

use strict;
use warnings;
use constant;

use Perl::Critic::Utils qw{ :severities };
use base 'Perl::Critic::Policy';

our $VERSION = '1.000';

use constant DESC => q{Request parameters are read raw};
use constant EXPL => q{Declare them with requestParams from Hydra::Helper::RequestParams, which parses them into the types the handler expects};

# The request methods that return parameters, or the decoded body.
my %rawMethods = map { $_ => 1 } qw(
    params param parameters
    query_params query_parameters
    body_params body_parameters body_data
    data
);

sub supported_parameters { return ()                 }
sub default_severity     { return $SEVERITY_HIGHEST  }
sub default_themes       { return qw( hydra security ) }
sub applies_to           { return 'PPI::Token::Word' }

sub violates {
    my ( $self, $elem, undef ) = @_;

    # A method call `->METHOD` on `->req` or `->request`.
    return () unless $rawMethods{$elem->content()};
    my $arrow = $elem->sprevious_sibling();
    return () unless _isArrow($arrow);
    my $request = $arrow->sprevious_sibling();
    return () unless $request && $request->isa('PPI::Token::Word') && $request->content() =~ /^(?:req|request)$/;
    my $requestArrow = $request->sprevious_sibling();
    return () unless _isArrow($requestArrow);

    # Allowed as the source `requestParams` decodes: `from => $c->req->params`.
    my $invocant = $requestArrow->sprevious_sibling();
    my $fatComma = $invocant && $invocant->sprevious_sibling();
    my $from = $fatComma && $fatComma->sprevious_sibling();
    return () if $fatComma && $fatComma->isa('PPI::Token::Operator') && $fatComma->content() eq '=>'
        && $from && $from->isa('PPI::Token::Word') && $from->content() eq 'from';

    # Allowed as arguments to `uri_for`, which only copies them into a URL.
    for (my $parent = $elem->parent(); $parent; $parent = $parent->parent()) {
        next unless $parent->isa('PPI::Structure::List');
        my $callee = $parent->sprevious_sibling();
        return () if $callee && $callee->isa('PPI::Token::Word') && $callee->content() eq 'uri_for';
    }

    return $self->violation( DESC, EXPL, $elem );
}

sub _isArrow {
    my ($elem) = @_;
    return $elem && $elem->isa('PPI::Token::Operator') && $elem->content() eq '->';
}

1;

__END__

=pod

=head1 NAME

Perl::Critic::Policy::Hydra::ProhibitRawRequestParams - Prohibit reading request parameters raw

=head1 DESCRIPTION

A request body can be JSON, so a parameter can arrive as any structure, and
DBIx::Class reads a hash or a list as query structure rather than as data.
Handlers therefore declare the type of each parameter they use with
C<requestParams> from L<Hydra::Helper::RequestParams>, rather than reading
C<< $c->req->params >>, C<< $c->req->param(...) >>, C<< $c->req->data >> and
the like directly.

This policy flags those reads, except:

=over

=item * as the C<from> argument of C<requestParams>, as in
C<< requestParams($c, { ... }, from => $c->req->params) >>;

=item * as arguments to C<uri_for>, which only copies them into a URL.

=back

C<Hydra::Helper::RequestParams> itself reads the request, and says so with
C<## no critic>.

=head1 CONFIGURATION

This Policy is not configurable except for the standard options.

=cut

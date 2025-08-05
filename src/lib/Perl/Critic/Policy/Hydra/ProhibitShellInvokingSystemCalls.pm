package Perl::Critic::Policy::Hydra::ProhibitShellInvokingSystemCalls;

use strict;
use warnings;
use constant;

use Perl::Critic::Utils qw{ :severities :classification :ppi };
use base 'Perl::Critic::Policy';

our $VERSION = '1.000';

use constant DESC => q{Shell-invoking system calls are prohibited};
use constant EXPL => q{Use list form system() or IPC::Run3 for better security. String form invokes shell and is vulnerable to injection};

sub supported_parameters { return ()                         }
sub default_severity     { return $SEVERITY_HIGHEST         }
sub default_themes       { return qw( hydra security )       }
sub applies_to           { return 'PPI::Token::Word'         }

sub violates {
    my ( $self, $elem, undef ) = @_;

    # Only check system() and exec() calls
    return () unless $elem->content() =~ /^(system|exec)$/;
    return () unless is_function_call($elem);

    # Skip method calls (->system or ->exec)
    my $prev = $elem->sprevious_sibling();
    return () if $prev && $prev->isa('PPI::Token::Operator') && $prev->content() eq '->';

    # Get first argument after function name, skipping whitespace
    my $args = $elem->snext_sibling();
    return () unless $args;
    $args = $args->snext_sibling() while $args && $args->isa('PPI::Token::Whitespace');

    # For parenthesized calls, look inside
    my $search_elem = $args;
    if ($args && $args->isa('PPI::Structure::List')) {
        $search_elem = $args->schild(0);
        return () unless $search_elem;
    }

    # Check if it's list form (has comma)
    my $current = $search_elem;
    if ($current && $current->isa('PPI::Statement')) {
        # Look through statement children
        for my $child ($current->schildren()) {
            return () if $child->isa('PPI::Token::Operator') && $child->content() eq ',';
        }
    } else {
        # Look through siblings for non-parenthesized calls
        while ($current) {
            return () if $current->isa('PPI::Token::Operator') && $current->content() eq ',';
            last if $current->isa('PPI::Token::Structure') && $current->content() eq ';';
            $current = $current->snext_sibling();
        }
    }

    # Check if first arg is array variable
    my $first = $search_elem->isa('PPI::Statement') ?
                $search_elem->schild(0) : $search_elem;
    return () if $first && $first->isa('PPI::Token::Symbol') && $first->content() =~ /^[@]/;

    # Check if it's a safe single-word command
    if ($first && $first->isa('PPI::Token::Quote')) {
        my $content = $first->string();
        return () if $content =~ /^[a-zA-Z0-9_\-\.\/]+$/;
    }

    return $self->violation( DESC, EXPL, $elem );
}

1;

__END__

=pod

=head1 NAME

Perl::Critic::Policy::Hydra::ProhibitShellInvokingSystemCalls - Prohibit shell-invoking system() and exec() calls

=head1 DESCRIPTION

This policy prohibits the use of C<system()> and C<exec()> functions when called with a single string argument,
which invokes the shell and is vulnerable to injection attacks.

The list form (e.g., C<system('ls', '-la')>) is allowed as it executes directly without shell interpretation.
For better error handling and output capture, consider using C<IPC::Run3>.

=head1 CONFIGURATION

This Policy is not configurable except for the standard options.

=head1 AUTHOR

Hydra Development Team

=head1 COPYRIGHT

Copyright (c) 2025 Hydra Development Team. All rights reserved.

=cut

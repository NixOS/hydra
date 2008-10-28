#!/var/run/current-system/sw/bin/perl -w

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Catalyst::Helper;

my $force = 0;
my $mech  = 0;
my $help  = 0;

GetOptions(
    'nonew|force'    => \$force,
    'mech|mechanize' => \$mech,
    'help|?'         => \$help
 );

pod2usage(1) if ( $help || !$ARGV[0] );

my $helper = Catalyst::Helper->new( { '.newfiles' => !$force, mech => $mech } );

pod2usage(1) unless $helper->mk_component( 'HydraFrontend', @ARGV );

1;

=head1 NAME

hydrafrontend_create.pl - Create a new Catalyst Component

=head1 SYNOPSIS

hydrafrontend_create.pl [options] model|view|controller name [helper] [options]

 Options:
   -force        don't create a .new file where a file to be created exists
   -mechanize    use Test::WWW::Mechanize::Catalyst for tests if available
   -help         display this help and exits

 Examples:
   hydrafrontend_create.pl controller My::Controller
   hydrafrontend_create.pl controller My::Controller BindLex
   hydrafrontend_create.pl -mechanize controller My::Controller
   hydrafrontend_create.pl view My::View
   hydrafrontend_create.pl view MyView TT
   hydrafrontend_create.pl view TT TT
   hydrafrontend_create.pl model My::Model
   hydrafrontend_create.pl model SomeDB DBIC::Schema MyApp::Schema create=dynamic\
   dbi:SQLite:/tmp/my.db
   hydrafrontend_create.pl model AnotherDB DBIC::Schema MyApp::Schema create=static\
   dbi:Pg:dbname=foo root 4321

 See also:
   perldoc Catalyst::Manual
   perldoc Catalyst::Manual::Intro

=head1 DESCRIPTION

Create a new Catalyst Component.

Existing component files are not overwritten.  If any of the component files
to be created already exist the file will be written with a '.new' suffix.
This behavior can be suppressed with the C<-force> option.

=head1 AUTHORS

Catalyst Contributors, see Catalyst.pm

=head1 COPYRIGHT

This library is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

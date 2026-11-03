package Nix::StorePath;

use strict;
use warnings;

# A store path: a bare `<hash>-<name>`, the same thing the C++ `StorePath` and
# the Rust `StorePath` are. The store directory is deliberately not part of it;
# putting one on or taking one off is the caller's business, not the bindings'.
#
# Represented as a blessed reference to the base name, so that it is a
# reference. That matters to callers using DBIx::Class, whose hashref writes
# only reach a column's deflator when the value is a ref.
#
# Stringifies to the base name, matching the C++ and Rust `to_string`. That
# also means an object can be handed straight to any of the binding functions
# below, which take the base name as a string.

use overload
    '""' => sub { $_[0]->to_string },
    # A store path object always names a path, so it is always true. Spelled
    # out rather than left to `fallback`, which would derive it from the
    # stringification and make an empty name silently false.
    'bool' => sub { 1 },
    fallback => 1;

my $hashLen = 32;
my $maxNameLen = 211;

sub new {
    my ($class, $baseName) = @_;
    die "store path must not be empty\n" if $baseName eq "";
    die "store path '$baseName' must not contain a '/'\n"
        if index($baseName, "/") != -1;
    die "store path '$baseName' is too short\n"
        if length($baseName) < $hashLen + 1;
    die "store path '$baseName' has an invalid hash part\n"
        unless substr($baseName, 0, $hashLen) =~ /\A[0-9a-df-np-sv-z]+\z/;
    die "store path '$baseName' has no dash after the hash part\n"
        unless substr($baseName, $hashLen, 1) eq "-";
    my $name = substr($baseName, $hashLen + 1);
    die "store path '$baseName' has an empty name\n" if $name eq "";
    die "store path '$baseName' has a name longer than $maxNameLen characters\n"
        if length($name) > $maxNameLen;
    die "store path '$baseName' has an illegal name\n"
        if $name =~ /\A\.\.?(?:-|\z)/
        || $name !~ /\A[A-Za-z0-9+\-._?=]+\z/;
    return bless \$baseName, $class;
}

sub to_string {
    my ($self) = @_;
    return $$self;
}

1;

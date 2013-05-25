package Hydra::Plugin;

use strict;
use Module::Pluggable
    search_path => "Hydra::Plugin",
    instantiate => 'new';

sub new {
    my ($class, %args) = @_;
    my $self = { db => $args{db}, config => $args{config} };
    bless $self, $class;
    return $self;
}

# Called when build $build has finished.  If the build failed, then
# $dependents is an array ref to a list of builds that have also
# failed as a result (i.e. because they depend on $build or a failed
# dependeny of $build).
sub buildFinished {
    my ($self, $build, $dependents) = @_;
}

# Called to determine the set of supported input types.  The plugin
# should add these to the $inputTypes hashref, e.g. $inputTypes{'svn'}
# = 'Subversion checkout'.
sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
}

# Called to fetch an input of type ‘$type’.  ‘$value’ is the input
# location, typically the repository URL.
sub fetchInput {
    my ($self, $type, $name, $value) = @_;
    return undef;
}

1;

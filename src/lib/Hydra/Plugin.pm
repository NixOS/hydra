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

1;

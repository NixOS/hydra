package Hydra::Plugin;

use strict;
use Module::Pluggable
    search_path => "Hydra::Plugin",
    instantiate => 'new';

sub new {
    my ($class, %args) = @_;
    my $self = { db => $args{db}, config => $args{config}, plugins => $args{plugins} };
    bless $self, $class;
    return $self;
}

sub isEnabled {
    return 1;
}

sub instantiate {
    my ($class, %args) = @_;
    my $plugins = [];
    $args{plugins} = $plugins;
    push @$plugins, grep { $_->isEnabled } $class->plugins(%args);
    return @$plugins;
}

# Called when build $build has been queued.
sub buildQueued {
    my ($self, $build) = @_;
}

# Called when build $build has started.
sub buildStarted {
    my ($self, $build) = @_;
}

# Called when build $build has finished.  If the build failed, then
# $dependents is an array ref to a list of builds that have also
# failed as a result (i.e. because they depend on $build or a failed
# dependeny of $build).
sub buildFinished {
    my ($self, $build, $dependents) = @_;
}

# Called when step $step has finished. The build log is stored in the
# file $logPath (bzip2-compressed).
sub stepFinished {
    my ($self, $step, $logPath) = @_;
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
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef;
}

# Get the commits to repository ‘$value’ between revisions ‘$rev1’ and
# ‘$rev2’.  Each commit should be a hash ‘{ revision = "..."; author =
# "..."; email = "..."; }’.
sub getCommits {
    my ($self, $type, $value, $rev1, $rev2) = @_;
    return [];
}

1;

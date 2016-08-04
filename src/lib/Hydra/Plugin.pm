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

sub instantiate {
    my ($class, %args) = @_;
    my $plugins = [];
    $args{plugins} = $plugins;
    push @$plugins, $class->plugins(%args);
    return @$plugins;
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

# Called to determine the set of supported input types. The plugin should add
# these to the $inputTypes hashref passed to the function.
#
# The value of it is another hashref, which defines some properties for handling
# that input type, like how to render the types properties or how to validate
# them.
#
# For example:
#
#   $inputTypes{'svn'} = {
#     name => 'Subversion checkout',
#     properties => {
#       uri => {label => "URI", required => 1},
#       revision => {label => "Revision"},
#     }
#   };
#
# The top-level of this consists of "name" (which is the user-visible name of
# the input type) and either "properties" or "singleton".
#
# The "properties" hashref is a collection of fields that can be set for a
# particular input and it maps from the name to another hashref specifying the
# information about that property:
#
#   label:    The label that is used for printing/editing
#   type:     The type of this property (for available types see below)
#   required: Whether the user is required to enter a value for this property
#   help:     A help text that is displayed as a tool tip
#   validate: A function that is used to validate the input (details below)
#
# All of these attributes are supported by "singleton" as well, because instead
# of a list of properties the "singleton" attribute designates only one possible
# input.
#
# Available property types:
#
#   bool:    Boolean
#   int:     Integer
#   attrset: A map between keys and values
#   string:  String
#
# If no property type is specified, the default is "string".
#
# The "validate" property attribute is a function which gets passed the
# following arguments in this order:
#
#   controller: The current Controller object
#   name:       The name of the jobset input
#   value:      The value of the property
#
# The "controller" argument is very useful to trigger errors, like for example:
#
#   myproperty => {
#     label    => "An example property",
#     validate => sub {
#       my ($c, $name, $value) = @_;
#       error($c, 'You have entered an evil value!') if $value eq "evil";
#     }
#   }
#
# In this case if "evil" is entered as the properties value, an error would be
# returned and displayed to the user.
#
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

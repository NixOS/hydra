package Hydra::Plugin;

use Module::Pluggable
    search_path => "Hydra::Plugin",
    require     => 1;

# $plugin->buildFinished($db, $config, $build, $dependents):
#
# Called when build $build has finished.  If the build failed, then
# $dependents is an array ref to a list of builds that have also
# failed as a result (i.e. because they depend on $build or a failed
# dependeny of $build).

1;

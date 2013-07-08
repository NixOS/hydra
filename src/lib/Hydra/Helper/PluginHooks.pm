package Hydra::Helper::PluginHooks;

use strict;
use Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    notifyBuildFinished);

sub notifyBuildFinished {
    my ($plugins, $build, $dependents) = @_;
    foreach my $plugin (@{$plugins}) {
        eval {
            $plugin->buildFinished($build, $dependents);
        };
        if ($@) {
            print STDERR "\$plugin->buildFinished: $@\n";
        }
    }
}

1;

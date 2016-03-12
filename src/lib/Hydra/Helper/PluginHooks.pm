package Hydra::Helper::PluginHooks;

use strict;
use Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    notifyBuildStarted
    notifyBuildFinished);

sub notifyBuildStarted {
    my ($plugins, $build) = @_;
    foreach my $plugin (@{$plugins}) {
        eval {
            $plugin->buildStarted($build);
        };
        if ($@) {
            print STDERR "$plugin->buildStarted: $@\n":
        }
    }
}

sub notifyBuildFinished {
    my ($plugins, $build, $dependents) = @_;
    foreach my $plugin (@{$plugins}) {
        eval {
            $plugin->buildFinished($build, $dependents);
        };
        if ($@) {
            print STDERR "$plugin->buildFinished: $@\n";
        }
    }
}

1;

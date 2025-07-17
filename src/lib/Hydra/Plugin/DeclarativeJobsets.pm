package Hydra::Plugin::DeclarativeJobsets;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use Hydra::Helper::AddBuilds;

sub buildFinished {
    my ($self, $build, $dependents) = @_;

    my $project = $build->project;
    my $jobsetName = $build->jobset->get_column('name');
    if (length($project->declfile) && $jobsetName eq ".jobsets" && $build->iscurrent) {
        handleDeclarativeJobsetBuild($self->{"db"}, $project, $build);
    }
}

1;

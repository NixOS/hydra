package HydraFrontend::Controller::Root;

use strict;
use warnings;
use parent 'Catalyst::Controller';

#
# Sets the actions in this controller to be registered with no prefix
# so they function identically to actions created in MyApp.pm
#
__PACKAGE__->config->{namespace} = '';


sub error {
    my ($c, $msg) = @_;
    $c->stash->{template} = 'error.tt';
    $c->stash->{error} = $msg;
    $c->response->status(404);
}


sub getBuild {
    my ($c, $id) = @_;
    (my $build) = $c->model('DB::Builds')->search({ id => $id });
    return $build;
}


sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'index.tt';
    $c->stash->{projects} = [$c->model('DB::Projects')->all];
    $c->stash->{scheduled} = [$c->model('DB::Builds')->search(
        {finished => 0}, {join => 'schedulingInfo'})]; # !!!
    $c->stash->{allBuilds} = [$c->model('DB::Builds')->search(
        {finished => 1}, {order_by => "timestamp DESC"})];
    # Get the latest finished build for each unique job.
    $c->stash->{latestBuilds} = [$c->model('DB::Builds')->search(undef,
        { join => 'resultInfo'
        , where => "finished != 0 and timestamp = (select max(timestamp) from Builds where project == me.project and attrName == me.attrName)"
        , order_by => "project, attrname"
        })];
}


sub project :Local {
    my ( $self, $c, $projectName ) = @_;
    $c->stash->{template} = 'project.tt';
    (my $project) = $c->model('DB::Projects')->search({ name => $projectName });
    return error($c, "Project <tt>$projectName</tt> doesn't exist.") if !defined $project;
    $c->stash->{project} = $project;
    $c->stash->{jobNames} =
        [$c->model('DB::Builds')->search({project => $projectName}, {select => [{distinct => 'attrname'}], as => ['attrname']})];
}


sub job :Local {
    my ( $self, $c, $project, $jobName ) = @_;
    $c->stash->{template} = 'job.tt';
    $c->stash->{projectName} = $project;
    $c->stash->{jobName} = $jobName;
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        {finished => 1, project => $project, attrName => $jobName},
        {order_by => "timestamp DESC"})];
}


sub default :Path {
    my ( $self, $c ) = @_;
    error($c, "Page not found.");
}


sub build :Local {
    my ( $self, $c, $id ) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    $c->stash->{template} = 'build.tt';
    $c->stash->{build} = $build;
    $c->stash->{id} = $id;
}


sub log :Local {
    my ( $self, $c, $id, $logPhase ) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    my $log = $build->buildlogs->find({logphase => $logPhase});
    return error($c, "Build $id doesn't have a log phase named <tt>$logPhase</tt>.") if !defined $log;
    
    $c->stash->{template} = 'log.tt';
    $c->stash->{id} = $id;
    $c->stash->{log} = $log;

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($log->path);
}


sub loadLog {
    my ($path) = @_;
    # !!! all a quick hack
    if ($path =~ /.bz2$/) {
        return `cat $path | bzip2 -d`;
    } else {
        return `cat $path`;
    }
}


sub end : ActionClass('RenderView') {}


1;

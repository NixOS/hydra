package Hydra::Base::Controller::ListBuilds;

use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub all : Chained('get_builds') PathPart {
    my ($self, $c) = @_;

    $c->stash->{template} = 'all.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    $c->stash->{baseUri} = $c->uri_for($self->action_for("all"), $c->req->captures);

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $c->stash->{allBuilds}->search({finished => 1})->count
        unless defined $c->stash->{total};

    $c->stash->{builds} = [ $c->stash->{allBuilds}->search(
        { finished => 1 },
        { order_by => "stoptime DESC"
        , columns => [@buildListColumns]
        , rows => $resultsPerPage
        , page => $page }) ];
}


sub nix : Chained('get_builds') PathPart('channel/latest') CaptureArgs(0) {
    my ($self, $c) = @_;

    $c->stash->{channelName} = $c->stash->{channelBaseName} . "-latest";
    $c->stash->{channelBuilds} = $c->stash->{latestSucceeded}
        ->search_literal("exists (select 1 from buildproducts where build = me.id and type = 'nix-build')")
        ->search({}, { columns => [@buildListColumns, 'drvpath', 'description', 'homepage']
                     , join => ["buildoutputs"]
                     , order_by => ["me.id", "buildoutputs.name"]
                     , '+select' => ['buildoutputs.path', 'buildoutputs.name'], '+as' => ['outpath', 'outname'] });
}


# Redirect to the latest successful build.
sub latest : Chained('get_builds') PathPart('latest') {
    my ($self, $c, @rest) = @_;

    my $latest = $c->stash->{allBuilds}->find(
        { finished => 1, buildstatus => 0 }, { order_by => ["id DESC"], rows => 1 });

    notFound($c, "There is no successful build to redirect to.") unless defined $latest;

    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("build"), [$latest->id], @rest));
}


# Redirect to the latest successful build's first output path (useful
# if the output is HTML (e.g. haddock documentation).
sub latest_outpath : Chained('get_builds') PathPart('latest-outpath') {
    my ($self, $c, @rest) = @_;

    my $latest = $c->stash->{allBuilds}->find(
        { finished => 1, buildstatus => 0 }, { order_by => ["id DESC"], rows => 1 });

    notFound($c, "There is no successful build to redirect to.") unless defined $latest;

    $c->res->redirect($c->uri_for(($latest->buildoutputs)[0]->path, @rest));
}


# Redirect to the latest successful build for a specific platform.
sub latest_for : Chained('get_builds') PathPart('latest-for') {
    my ($self, $c, $system, @rest) = @_;

    notFound($c, "You need to specify a platform type in the URL.") unless defined $system;

    my $latest = $c->stash->{allBuilds}->find(
        { finished => 1, buildstatus => 0, system => $system }, { order_by => ["id DESC"], rows => 1 });

    notFound($c, "There is no successful build for platform `$system' to redirect to.") unless defined $latest;

    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("build"), [$latest->id], @rest));
}


# Redirect to the latest successful build in a finished evaluation
# (i.e. an evaluation that has no unfinished builds).
sub latest_finished : Chained('get_builds') PathPart('latest-finished') {
    my ($self, $c, @rest) = @_;

    my $latest = $c->stash->{allBuilds}->find(
        { finished => 1, buildstatus => 0 },
        { order_by => ["id DESC"], rows => 1, join => ["jobsetevalmembers"]
        , where => \
            "not exists (select 1 from jobsetevalmembers m2 join builds b2 on jobsetevalmembers.eval = m2.eval and m2.build = b2.id and b2.finished = 0)"
        });

    notFound($c, "There is no successful build to redirect to.") unless defined $latest;

    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("build"), [$latest->id], @rest));
}


1;

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
        { order_by => "stop_time DESC"
        , columns => [@buildListColumns]
        , rows => $resultsPerPage
        , page => $page }) ];
}


sub nix : Chained('get_builds') PathPart('channel/latest') CaptureArgs(0) {
    my ($self, $c) = @_;

    $c->stash->{channelName} = $c->stash->{channelBaseName} . "-latest";
    $c->stash->{channelBuilds} = $c->stash->{latestSucceeded}
        ->search_literal("exists (select 1 from build_products where build = me.id and type = 'nix-build')")
        ->search({}, { columns => [@buildListColumns, 'drv_path', 'description', 'homepage']
                     , join => ["build_outputs"]
                     , order_by => ["me.id", "build_outputs.name"]
                     , '+select' => ['build_outputs.path', 'build_outputs.name'], '+as' => ['outpath', 'outname'] });
}


# Redirect to the latest successful build.
sub latest : Chained('get_builds') PathPart('latest') {
    my ($self, $c, @rest) = @_;

    my $latest = $c->stash->{allBuilds}->find(
        { finished => 1, build_status => 0 }, { order_by => ["id DESC"], rows => 1 });

    notFound($c, "There is no successful build to redirect to.") unless defined $latest;

    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("build"), [$latest->id], @rest));
}


# Redirect to the latest successful build for a specific platform.
sub latest_for : Chained('get_builds') PathPart('latest-for') {
    my ($self, $c, $system, @rest) = @_;

    notFound($c, "You need to specify a platform type in the URL.") unless defined $system;

    my $latest = $c->stash->{allBuilds}->find(
        { finished => 1, build_status => 0, system => $system }, { order_by => ["id DESC"], rows => 1 });

    notFound($c, "There is no successful build for platform `$system' to redirect to.") unless defined $latest;

    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("build"), [$latest->id], @rest));
}


# Redirect to the latest successful build in a finished evaluation
# (i.e. an evaluation that has no unfinished builds).
sub latest_finished : Chained('get_builds') PathPart('latest-finished') {
    my ($self, $c, @rest) = @_;

    my $latest = $c->stash->{allBuilds}->find(
        { finished => 1, build_status => 0 },
        { order_by => ["id DESC"], rows => 1, join => ["jobset_eval_members"]
        , where => \
            "not exists (select 1 from jobset_eval_members m2 join builds b2 on jobset_eval_members.eval = m2.eval and m2.build = b2.id and b2.finished = 0)"
        });

    notFound($c, "There is no successful build to redirect to.") unless defined $latest;

    $c->res->redirect($c->uri_for($c->controller('Build')->action_for("build"), [$latest->id], @rest));
}


1;

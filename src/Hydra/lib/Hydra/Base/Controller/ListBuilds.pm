package Hydra::Base::Controller::ListBuilds;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub jobstatus : Chained('get_builds') PathPart Args(0) {
    my ($self, $c) = @_;
    $c->stash->{latestBuilds} = getLatestBuilds($c, $c->stash->{allBuilds}, {});
}

    
sub all : Chained('get_builds') PathPart {
    my ($self, $c, $page) = @_;

    $c->stash->{template} = 'all.tt';

    $page = (defined $page ? int($page) : 1) || 1;

    my $resultsPerPage = 50;

    my $nrBuilds = scalar($c->stash->{allBuilds}->search({finished => 1}));

    $c->stash->{baseUri} = $c->uri_for($self->action_for("all"), $c->req->captures);

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{totalBuilds} = $nrBuilds;

    $c->stash->{builds} = [$c->stash->{allBuilds}->search(
        {finished => 1}, {order_by => "timestamp DESC", rows => $resultsPerPage, page => $page})];
}


1;

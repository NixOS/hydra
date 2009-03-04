package Hydra::Base::Controller::ListBuilds;

use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
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


sub nix : Chained('get_builds') PathPart('channel') CaptureArgs(1) {
    my ($self, $c, $channelName) = @_;
    eval {
        if ($channelName eq "latest") {
            $c->stash->{channelName} = $c->stash->{channelBaseName} . "-latest";
            getChannelData($c, getLatestBuilds($c, $c->stash->{allBuilds}, {buildStatus => 0}));
        }
        elsif ($channelName eq "all") {
            $c->stash->{channelName} = $c->stash->{channelBaseName} . "-all";
            getChannelData($c, [$c->stash->{allBuilds}->all]);
        }
        else {
            error($c, "Unknown channel `$channelName'.");
        }
    };
    error($c, $@) if $@;
}


1;

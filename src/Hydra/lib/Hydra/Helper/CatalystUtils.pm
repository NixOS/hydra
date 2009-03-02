package Hydra::Helper::CatalystUtils;

use strict;
use Exporter;
use Readonly;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getBuild error notFound
    requireLogin requireProjectOwner
    $pathCompRE $relPathRE
);


sub getBuild {
    my ($c, $id) = @_;
    my $build = $c->model('DB::Builds')->find($id);
    return $build;
}


sub error {
    my ($c, $msg) = @_;
    $c->error($msg);
    $c->detach; # doesn't return
}


sub notFound {
    my ($c, $msg) = @_;
    $c->response->status(404);
    error($c, $msg);
}


sub requireLogin {
    my ($c) = @_;
    $c->flash->{afterLogin} = $c->request->uri;
    $c->response->redirect($c->uri_for('/login'));
    $c->detach; # doesn't return
}


sub requireProjectOwner {
    my ($c, $project) = @_;
    
    requireLogin($c) if !$c->user_exists;
    
    error($c, "Only the project owner or the administrator can perform this operation.")
        unless $c->check_user_roles('admin') || $c->user->username eq $project->owner->username;
}


# Security checking of filenames.
Readonly::Scalar our $pathCompRE => "(?:[A-Za-z0-9-\+][A-Za-z0-9-\+\._]*)";
Readonly::Scalar our $relPathRE  => "(?:$pathCompRE(?:\/$pathCompRE)*)";


1;

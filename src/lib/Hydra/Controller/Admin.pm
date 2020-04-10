package Hydra::Controller::Admin;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Data::Dump qw(dump);
use Digest::SHA1 qw(sha1_hex);
use Config::General;


sub admin : Chained('/') PathPart('admin') CaptureArgs(0) {
    my ($self, $c) = @_;
    requireAdmin($c);
    $c->stash->{admin} = 1;
}


sub users : Chained('admin') PathPart('users') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{users} = [$c->model('DB::Users')->search({}, {order_by => "username"})];
    $c->stash->{template} = 'users.tt';
}


sub machines : Chained('admin') PathPart('machines') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{machines} = getMachines;
    $c->stash->{template} = 'machines.tt';
}


sub clear_queue_non_current : Chained('admin') PathPart('clear-queue-non-current') Args(0) {
    my ($self, $c) = @_;
    my $builds = $c->model('DB::Builds')->search(
        { id => { -in => \ "select id from Builds where id in ((select id from Builds where finished = 0) except (select build from JobsetEvalMembers where eval in (select max(id) from JobsetEvals where hasNewBuilds = 1 group by project, jobset)))" }
        });
    my $n = cancelBuilds($c->model('DB')->schema, $builds);
    $c->flash->{successMsg} = "$n builds have been cancelled.";
    $c->res->redirect($c->request->referer // "/");
}


sub clearfailedcache : Chained('admin') PathPart('clear-failed-cache') Args(0) {
    my ($self, $c) = @_;
    $c->model('DB::FailedPaths')->delete;
    $c->res->redirect($c->request->referer // "/");
}


sub clearvcscache : Chained('admin') PathPart('clear-vcs-cache') Args(0) {
    my ($self, $c) = @_;
    $c->model('DB::CachedPathInputs')->delete;
    $c->model('DB::CachedGitInputs')->delete;
    $c->model('DB::CachedSubversionInputs')->delete;
    $c->model('DB::CachedBazaarInputs')->delete;
    $c->flash->{successMsg} = "VCS caches have been cleared.";
    $c->res->redirect($c->request->referer // "/");
}


sub managenews : Chained('admin') PathPart('news') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, {order_by => 'createtime DESC'})];

    $c->stash->{template} = 'news.tt';
}


sub news_submit : Chained('admin') PathPart('news/submit') Args(0) {
    my ($self, $c) = @_;

    requirePost($c);

    my $contents = trim $c->request->params->{"contents"};
    my $createtime = time;

    $c->model('DB::NewsItems')->create({
        createtime => $createtime,
        contents => $contents,
        author => $c->user->username
    });

    $c->res->redirect("/admin/news");
}


sub news_delete : Chained('admin') PathPart('news/delete') Args(1) {
    my ($self, $c, $id) = @_;

    $c->model('DB')->schema->txn_do(sub {
        my $newsItem = $c->model('DB::NewsItems')->find($id)
          or notFound($c, "Newsitem with id $id doesn't exist.");
        $newsItem->delete;
    });

    $c->res->redirect("/admin/news");
}


1;

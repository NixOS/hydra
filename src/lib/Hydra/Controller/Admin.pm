package Hydra::Controller::Admin;

use strict;
use warnings;
use base 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub admin : Chained('/') PathPart('admin') CaptureArgs(0) {
    my ($self, $c) = @_;
    requireAdmin($c);
}

sub index : Chained('admin') PathPart('') Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'admin.tt';
}

sub clearfailedcache : Chained('admin') Path('clear-failed-cache') Args(0) {
    my ($self, $c) = @_;

    my $r = `nix-store --clear-failed-paths '*'`;

    $c->res->redirect("/admin");
}

sub clearevalcache : Chained('admin') Path('clear-eval-cache') Args(0) {
    my ($self, $c) = @_;

    print "Clearing evaluation cache\n";
    $c->model('DB::JobsetInputHashes')->delete_all;

    $c->res->redirect("/admin");
}

sub clearvcscache : Chained('admin') Path('clear-vcs-cache') Args(0) {
    my ($self, $c) = @_;

    print "Clearing path cache\n";
    $c->model('DB::CachedPathInputs')->delete_all;
    
    print "Clearing git cache\n";
    $c->model('DB::CachedGitInputs')->delete_all;

    print "Clearing subversion cache\n";
    $c->model('DB::CachedSubversionInputs')->delete_all;

    $c->res->redirect("/admin");
}

sub managenews : Chained('admin') Path('news') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, {order_by => 'createtime DESC'})];

    $c->stash->{template} = 'news.tt';    
}

sub news_submit : Chained('admin') Path('news/submit') Args(0) {
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

sub news_delete : Chained('admin') Path('news/delete') Args(1) {
    my ($self, $c, $id) = @_;

    txn_do($c->model('DB')->schema, sub {
        my $newsItem = $c->model('DB::NewsItems')->find($id)
          or notFound($c, "Newsitem with id $id doesn't exist.");
        $newsItem->delete;
    });
        
    $c->res->redirect("/admin/news");
}

1;

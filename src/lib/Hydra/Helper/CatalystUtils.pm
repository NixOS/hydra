package Hydra::Helper::CatalystUtils;

use utf8;
use strict;
use Exporter;
use Readonly;
use Nix::Store;
use Hydra::Helper::Nix;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getBuild getPreviousBuild getNextBuild getPreviousSuccessfulBuild
    error notFound
    requireLogin requireProjectOwner requireAdmin requirePost isAdmin isProjectOwner
    trim
    getLatestFinishedEval
    parseJobsetName
    $pathCompRE $relPathRE $relNameRE $projectNameRE $jobsetNameRE $jobNameRE $systemRE $userNameRE
    @buildListColumns
);


# Columns from the Builds table needed to render build lists.
Readonly our @buildListColumns => ('id', 'finished', 'timestamp', 'project', 'jobset', 'job', 'nixname', 'system', 'priority', 'busy', 'buildstatus', 'releasename');


sub getBuild {
    my ($c, $id) = @_;
    my $build = $c->model('DB::Builds')->find($id);
    return $build;
}


sub getPreviousBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $prevBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , 'me.id' =>  { '<' => $build->id }
      }, {rows => 1, order_by => "me.id DESC"});

    return $prevBuild;
}


sub getNextBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $nextBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , 'me.id' =>  { '>' => $build->id }
      }, {rows => 1, order_by => "me.id ASC"});

    return $nextBuild;
}


sub getPreviousSuccessfulBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $prevBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , buildstatus => 0
      , 'me.id' =>  { '<' => $build->id }
      }, {rows => 1, order_by => "me.id DESC"});

    return $prevBuild;
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
    $c->response->redirect($c->uri_for('/login'));
    $c->detach; # doesn't return
}


sub isProjectOwner {
    my ($c, $project) = @_;

    return $c->user_exists && ($c->check_user_roles('admin') || $c->user->username eq $project->owner->username || defined $c->model('DB::ProjectMembers')->find({ project => $project, userName => $c->user->username }));
}


sub requireProjectOwner {
    my ($c, $project) = @_;

    requireLogin($c) if !$c->user_exists;

    error($c, "Only the project members or administrators can perform this operation.")
        unless isProjectOwner($c, $project);
}


sub isAdmin {
    my ($c) = @_;

    return $c->user_exists && $c->check_user_roles('admin');
}


sub requireAdmin {
    my ($c) = @_;

    requireLogin($c) if !$c->user_exists;

    error($c, "Only administrators can perform this operation.")
        unless isAdmin($c);
}


sub requirePost {
    my ($c) = @_;
    error($c, "Request must be POSTed.") if $c->request->method ne "POST";
}


sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}


sub getLatestFinishedEval {
    my ($c, $jobset) = @_;
    my ($eval) = $jobset->jobsetevals->search(
        { hasnewbuilds => 1 },
        { order_by => "id DESC", rows => 1
        , where => \ "not exists (select 1 from JobsetEvalMembers m join Builds b on m.build = b.id where m.eval = me.id and b.finished = 0)"
        });
    return $eval;
}


# Security checking of filenames.
Readonly our $pathCompRE    => "(?:[A-Za-z0-9-\+\._\$][A-Za-z0-9-\+\._\$]*)";
Readonly our $relPathRE     => "(?:$pathCompRE(?:/$pathCompRE)*)";
Readonly our $relNameRE     => "(?:[A-Za-z0-9-][A-Za-z0-9-\.]*)";
Readonly our $attrNameRE    => "(?:[A-Za-z_][A-Za-z0-9-_]*)";
Readonly our $projectNameRE => "(?:[A-Za-z_][A-Za-z0-9-_]*)";
Readonly our $jobsetNameRE  => "(?:[A-Za-z_][A-Za-z0-9-_]*)";
Readonly our $jobNameRE     => "(?:$attrNameRE(?:\\.$attrNameRE)*)";
Readonly our $systemRE      => "(?:[a-z0-9_]+-[a-z0-9_]+)";
Readonly our $userNameRE    => "(?:[a-z][a-z0-9_\.]*)";


sub parseJobsetName {
    my ($s) = @_;
    $s =~ /^($projectNameRE):($jobsetNameRE)$/ or die "invalid jobset specifier ‘$s’\n";
    return ($1, $2);
}


1;

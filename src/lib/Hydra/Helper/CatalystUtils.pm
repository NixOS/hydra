package Hydra::Helper::CatalystUtils;

use utf8;
use strict;
use Exporter;
use Readonly;
use Email::Simple;
use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP;
use Sys::Hostname::Long;
use Nix::Store;
use Hydra::Helper::Nix;
use feature qw/switch/;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getBuild getPreviousBuild getNextBuild getPreviousSuccessfulBuild
    error notFound gone accessDenied
    forceLogin requireUser requireProjectOwner requireAdmin requirePost isAdmin isProjectOwner
    trim
    getLatestFinishedEval
    sendEmail
    paramToList
    backToReferer
    $pathCompRE $relPathRE $relNameRE $projectNameRE $jobsetNameRE $jobNameRE $systemRE $userNameRE $inputNameRE
    @buildListColumns
    parseJobsetName
    showJobName
    showStatus
    getResponsibleAuthors
    setCacheHeaders
);


# Columns from the Builds table needed to render build lists.
Readonly our @buildListColumns => ('id', 'finished', 'timestamp', 'stoptime', 'project', 'jobset', 'job', 'nixname', 'system', 'priority', 'busy', 'buildstatus', 'releasename');


sub getBuild {
    my ($c, $id) = @_;
    my $build = $c->model('DB::Builds')->find($id);
    return $build;
}


sub getPreviousBuild {
    my ($build) = @_;
    return undef if !defined $build;
    return $build->job->builds->search(
      { finished => 1
      , system => $build->system
      , 'me.id' =>  { '<' => $build->id }
        , -not => { buildstatus => { -in => [4, 3]} }
      }, { rows => 1, order_by => "me.id DESC" })->single;
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
    my ($c, $msg, $status) = @_;
    $c->response->status($status) if defined $status;
    $c->error($msg);
    $c->detach; # doesn't return
}


sub notFound {
    my ($c, $msg) = @_;
    error($c, $msg, 404);
}


sub gone {
    my ($c, $msg) = @_;
    error($c, $msg, 410);
}


sub accessDenied {
    my ($c, $msg) = @_;
    error($c, $msg, 403);
}


sub backToReferer {
    my ($c) = @_;
    $c->response->redirect($c->session->{referer} || $c->uri_for('/'));
    $c->session->{referer} = undef;
    $c->detach;
}


sub forceLogin {
    my ($c) = @_;
    $c->session->{referer} = $c->request->uri;
    accessDenied($c, "This page requires you to sign in.");
}


sub requireUser {
    my ($c) = @_;
    forceLogin($c) if !$c->user_exists;
}


sub isProjectOwner {
    my ($c, $project) = @_;
    return
        $c->user_exists &&
        (isAdmin($c) ||
         $c->user->username eq $project->owner->username ||
         defined $c->model('DB::ProjectMembers')->find({ project => $project, userName => $c->user->username }));
}


sub requireProjectOwner {
    my ($c, $project) = @_;
    requireUser($c);
    accessDenied($c, "Only the project members or administrators can perform this operation.")
        unless isProjectOwner($c, $project);
}


sub isAdmin {
    my ($c) = @_;
    return $c->user_exists && $c->check_user_roles('admin');
}


sub requireAdmin {
    my ($c) = @_;
    requireUser($c);
    accessDenied($c, "Only administrators can perform this operation.")
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
    my ($jobset) = @_;
    my ($eval) = $jobset->jobsetevals->search(
        { hasnewbuilds => 1 },
        { order_by => "id DESC", rows => 1
        , where => \ "not exists (select 1 from JobsetEvalMembers m join Builds b on m.build = b.id where m.eval = me.id and b.finished = 0)"
        });
    return $eval;
}


sub sendEmail {
    my ($c, $to, $subject, $body) = @_;

    my $sender = $c->config->{'notification_sender'} ||
        (($ENV{'USER'} || "hydra") .  "@" . hostname_long);

    my $email = Email::Simple->create(
        header => [
            To      => $to,
            From    => "Hydra <$sender>",
            Subject => $subject
        ],
        body => $body
    );

    print STDERR "Sending email:\n", $email->as_string if $ENV{'HYDRA_MAIL_TEST'};

    sendmail($email);
}


# Catalyst request parameters can be an array or a scalar or
# undefined, making them annoying to handle.  So this utility function
# always returns a request parameter as a list.
sub paramToList {
    my ($c, $name) = @_;
    my $x = $c->stash->{params}->{$name};
    return () unless defined $x;
    return @$x if ref($x) eq 'ARRAY';
    return ($x);
}


# Security checking of filenames.
Readonly our $pathCompRE    => "(?:[A-Za-z0-9-\+\._\$][A-Za-z0-9-\+\._\$:]*)";
Readonly our $relPathRE     => "(?:$pathCompRE(?:/$pathCompRE)*)";
Readonly our $relNameRE     => "(?:[A-Za-z0-9-_][A-Za-z0-9-\._]*)";
Readonly our $attrNameRE    => "(?:[A-Za-z_][A-Za-z0-9-_]*)";
Readonly our $projectNameRE => "(?:[A-Za-z_][A-Za-z0-9-_]*)";
Readonly our $jobsetNameRE  => "(?:[A-Za-z_][A-Za-z0-9-_\.]*)";
Readonly our $jobNameRE     => "(?:$attrNameRE(?:\\.$attrNameRE)*)";
Readonly our $systemRE      => "(?:[a-z0-9_]+-[a-z0-9_]+)";
Readonly our $userNameRE    => "(?:[a-z][a-z0-9_\.]*)";
Readonly our $inputNameRE   => "(?:[A-Za-z_][A-Za-z0-9-_]*)";


sub parseJobsetName {
    my ($s) = @_;
    $s =~ /^($projectNameRE):($jobsetNameRE)$/ or die "invalid jobset specifier ‘$s’\n";
    return ($1, $2);
}


sub showJobName {
    my ($build) = @_;
    return $build->project->name . ":" . $build->jobset->name . ":" . $build->job->name;
}


sub showStatus {
    my ($build) = @_;

    my $status = "Failed";
    given ($build->buildstatus) {
        when (0) { $status = "Success"; }
        when (1) { $status = "Failed"; }
        when (2) { $status = "Dependency failed"; }
        when (4) { $status = "Cancelled"; }
        when (6) { $status = "Failed with output"; }
    }

   return $status;
}


# Determine who broke/fixed the build.
sub getResponsibleAuthors {
    my ($build, $plugins) = @_;

    my $prevBuild = getPreviousBuild($build);

    my $nrCommits = 0;
    my %authors;
    my @emailable_authors;

    if ($prevBuild) {
        foreach my $curInput ($build->buildinputs_builds) {
            next unless ($curInput->type eq "git" || $curInput->type eq "hg");
            my $prevInput = $prevBuild->buildinputs_builds->find({ name => $curInput->name });
            next unless defined $prevInput;

            next if $curInput->type ne $prevInput->type;
            next if $curInput->uri ne $prevInput->uri;
            next if $curInput->revision eq $prevInput->revision;

            my @commits;
            foreach my $plugin (@{$plugins}) {
                push @commits, @{$plugin->getCommits($curInput->type, $curInput->uri, $prevInput->revision, $curInput->revision)};
            }

            foreach my $commit (@commits) {
                #print STDERR "$commit->{revision} by $commit->{author}\n";
                $authors{$commit->{author}} = $commit->{email};
                push @emailable_authors, $commit->{email} if $curInput->emailresponsible;
                $nrCommits++;
            }
        }
    }

    return (\%authors, $nrCommits, \@emailable_authors);
}


# Set HTTP headers for the Nix binary cache.
sub setCacheHeaders {
    my ($c, $expiration) = @_;
    $c->response->headers->expires(time + $expiration);
    delete $c->response->cookies->{hydra_session};
}


1;

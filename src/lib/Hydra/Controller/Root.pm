package Hydra::Controller::Root;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Digest::SHA1 qw(sha1_hex);

# Put this controller at top-level.
__PACKAGE__->config->{namespace} = '';


sub begin :Private {
    my ($self, $c, @args) = @_;
    $c->stash->{curUri} = $c->request->uri;
    $c->stash->{version} = $ENV{"HYDRA_RELEASE"} || "<devel>";
    $c->stash->{nixVersion} = $ENV{"NIX_RELEASE"} || "<devel>";
    $c->stash->{curTime} = time;
    $c->stash->{logo} = $ENV{"HYDRA_LOGO"} ? "/logo" : "/static/images/hydra.png" ;
    $c->stash->{tracker} = $ENV{"HYDRA_TRACKER"} ;

    if (scalar(@args) == 0 || $args[0] ne "static") {
      $c->stash->{nrRunningBuilds} = $c->model('DB::BuildSchedulingInfo')->search({ busy => 1 }, {})->count();
      $c->stash->{nrQueuedBuilds} = $c->model('DB::BuildSchedulingInfo')->count();
    }
}


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'overview.tt';
    $c->stash->{projects} = [$c->model('DB::Projects')->search(isAdmin($c) ? {} : {hidden => 0}, {order_by => 'name'})];
    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, { order_by => ['createtime DESC'], rows => 5 })];
#    $c->stash->{nrbuilds} = [nrbuildsQuery($c, 30, "day", "", "", "", "")];
    # <img src="http://chart.apis.google.com/chart?cht=bvg&chtt=Nr%20builds%20over%20the%20last%2030%20days&chs=300x100&chd=t:1785,881,2863,2828,1472,2847,1449,5634,1625,1200,1576,700,839,8533,1439,361,991,1337,1234,1322,1883,2146,1553,883,378,1395,1204,527,1147,124&chco=BBCEBB&chds=0,8533&chbh=a&chxt=y&chxr=0,0,8533"/>
}


sub login :Local {
    my ($self, $c) = @_;

    my $username = $c->request->params->{username} || "";
    my $password = $c->request->params->{password} || "";

    if ($username eq "" && $password eq "" && ! defined $c->flash->{referer}) {
        my $baseurl = $c->uri_for('/');
        my $refurl = $c->request->referer;
        $c->flash->{referer} = $refurl if $refurl =~ m/^($baseurl)/;
    }

    if ($username && $password) {
        if ($c->authenticate({username => $username, password => $password})) {
            $c->response->redirect($c->flash->{referer} || $c->uri_for('/'));
            $c->flash->{referer} = undef;
            return;
        }
        $c->stash->{errorMsg} = "Bad username or password.";
    }

    $c->stash->{template} = 'login.tt';
}


sub logout :Local {
    my ($self, $c) = @_;
    $c->logout;
    $c->response->redirect($c->request->referer || $c->uri_for('/'));
}


sub queue :Local {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue.tt';
    $c->stash->{queue} = [$c->model('DB::Builds')->search(
        {finished => 0}, {join => ['schedulingInfo', 'project'] , order_by => ["priority DESC", "timestamp"], '+select' => ['project.enabled', 'schedulingInfo.priority', 'schedulingInfo.disabled', 'schedulingInfo.busy'], '+as' => ['enabled', 'priority', 'disabled', 'busy']  })];
    $c->stash->{flashMsg} = $c->flash->{buildMsg};
}


sub timeline :Local {
    my ($self, $c) = @_;
    my $pit = time();
    $c->stash->{pit} = $pit;
    $pit = $pit-(24*60*60)-1;

    $c->stash->{template} = 'timeline.tt';
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        {finished => 1, stoptime => { '>' => $pit } }
      , { join => 'resultInfo'
        , order_by => ["starttime"]
        , '+select' => [ 'resultInfo.starttime', 'resultInfo.stoptime', 'resultInfo.buildstatus' ]
        , '+as' => [ 'starttime', 'stoptime', 'buildstatus' ]
        })];
}


sub status :Local {
    my ($self, $c) = @_;
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { 'me.busy' => 1, 'schedulingInfo.busy' => 1 },
        { join => [ 'schedulingInfo', 'build' ]
        , order_by => [ 'machine' ]
        } ) ];
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('/') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->model('DB::Builds');
    $c->stash->{jobStatus} = $c->model('DB')->resultset('JobStatus');
    $c->stash->{allJobsets} = $c->model('DB::Jobsets');
    $c->stash->{allJobs} = $c->model('DB::Jobs');
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceeded');
    $c->stash->{channelBaseName} = "everything";
}


sub robots_txt : Path('robots.txt') {
    my ($self, $c) = @_;

    sub uri_for {
        my ($controller, $action, @args) = @_;
        return $c->uri_for($c->controller($controller)->action_for($action), @args)->path;
    }

    sub channelUris {
        my ($controller, $bindings) = @_;
        return
            ( uri_for($controller, 'closure', $bindings, "*")
            , uri_for($controller, 'manifest', $bindings)
            , uri_for($controller, 'pkg', $bindings, "*")
            , uri_for($controller, 'nixexprs', $bindings)
            , uri_for($controller, 'channel_contents', $bindings)
            );
    }

    # Put actions that are expensive or not useful for indexing in
    # robots.txt.  Note: wildcards are not universally supported in
    # robots.txt, but apparently Google supports them.
    my @rules =
        ( uri_for('Build', 'buildtimedeps', ["*"])
        , uri_for('Build', 'runtimedeps', ["*"])
        , uri_for('Build', 'deps', ["*"])
        , uri_for('Build', 'view_nixlog', ["*"], "*")
        , uri_for('Build', 'view_log', ["*"], "*")
        , uri_for('Build', 'view_log', ["*"])
        , uri_for('Build', 'download', ["*"], "*")
        , uri_for('Root', 'nar', [], "*")
        , uri_for('Root', 'status', [])
        , uri_for('Root', 'all', [])
        , uri_for('Project', 'all', ["*"])
        , channelUris('Root', ["*"])
        , channelUris('Project', ["*", "*"])
        , channelUris('Jobset', ["*", "*", "*"])
        , channelUris('Job', ["*", "*", "*", "*"])
        , channelUris('Build', ["*"])
        );

    $c->stash->{'plain'} = { data => "User-agent: *\n" . join('', map { "Disallow: $_\n" } @rules) };
    $c->forward('Hydra::View::Plain');
}


sub default :Path {
    my ($self, $c) = @_;
    notFound($c, "Page not found.");
}


sub end : ActionClass('RenderView') {
    my ($self, $c) = @_;

    if (scalar @{$c->error}) {
        $c->stash->{template} = 'error.tt';
        $c->stash->{errors} = $c->error;
        if ($c->response->status >= 300) {
            $c->stash->{httpStatus} =
                $c->response->status . " " . HTTP::Status::status_message($c->response->status);
        }
        $c->clear_errors;
    }
}


sub nar :Local :Args(1) {
    my ($self, $c, $path) = @_;

    $path = ($ENV{NIX_STORE_DIR} || "/nix/store")."/$path";

    if (!isValidPath($path)) {
        $c->response->status(410); # "Gone"
        error($c, "Path " . $path . " is no longer available.");
    }

    $c->stash->{current_view} = 'NixNAR';
    $c->stash->{storePath} = $path;
}

sub change_password : Path('change-password') : Args(0) {
    my ($self, $c) = @_;

    requireLogin($c) if !$c->user_exists;

    $c->stash->{template} = 'change-password.tt';
}

sub change_password_submit : Path('change-password/submit') : Args(0) {
    my ($self, $c) = @_;

    requireLogin($c) if !$c->user_exists;

    my $password = $c->request->params->{"password"};
    my $password_check = $c->request->params->{"password_check"};
    print STDERR "$password \n";
    print STDERR "$password_check \n";
    error($c, "Passwords did not match, go back and try again!") if $password ne $password_check;

    my $hashed = sha1_hex($password);
    $c->user->update({ password => $hashed}) ;

    $c->res->redirect("/");
}

sub logo :Local {
    my ($self, $c) = @_;
    my $path = $ENV{"HYDRA_LOGO"} or die("Logo not set!");
    $c->serve_static_file($path);
}


1;

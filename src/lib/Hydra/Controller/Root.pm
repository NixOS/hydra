package Hydra::Controller::Root;

use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Digest::SHA1 qw(sha1_hex);
use Nix::Store;
use Nix::Config;

# Put this controller at top-level.
__PACKAGE__->config->{namespace} = '';


sub begin :Private {
    my ($self, $c, @args) = @_;
    $c->stash->{curUri} = $c->request->uri;
    $c->stash->{version} = $ENV{"HYDRA_RELEASE"} || "<devel>";
    $c->stash->{nixVersion} = $ENV{"NIX_RELEASE"} || "<devel>";
    $c->stash->{curTime} = time;
    $c->stash->{logo} = $ENV{"HYDRA_LOGO"} ? "/logo" : "";
    $c->stash->{tracker} = $ENV{"HYDRA_TRACKER"};
    $c->stash->{flashMsg} = $c->flash->{flashMsg};
    $c->stash->{successMsg} = $c->flash->{successMsg};

    if (scalar(@args) == 0 || $args[0] ne "static") {
        $c->stash->{nrRunningBuilds} = $c->model('DB::Builds')->search({ finished => 0, busy => 1 }, {})->count();
        $c->stash->{nrQueuedBuilds} = $c->model('DB::Builds')->search({ finished => 0 })->count();
    }
}


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'overview.tt';
    $c->stash->{projects} = [$c->model('DB::Projects')->search(isAdmin($c) ? {} : {hidden => 0}, {order_by => 'name'})];
    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, { order_by => ['createtime DESC'], rows => 5 })];
}


sub queue :Local {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue.tt';
    $c->stash->{queue} = [$c->model('DB::Builds')->search(
        {finished => 0}, { join => ['project'], order_by => ["priority DESC", "timestamp"], columns => [@buildListColumns], '+select' => ['project.enabled'], '+as' => ['enabled'] })];
    $c->stash->{flashMsg} //= $c->flash->{buildMsg};
}


sub timeline :Local {
    my ($self, $c) = @_;
    my $pit = time();
    $c->stash->{pit} = $pit;
    $pit = $pit-(24*60*60)-1;

    $c->stash->{template} = 'timeline.tt';
    $c->stash->{builds} = [ $c->model('DB::Builds')->search
        ( { finished => 1, stoptime => { '>' => $pit } }
        , { order_by => ["starttime"] }
        ) ];
}


sub status :Local {
    my ($self, $c) = @_;
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { 'me.busy' => 1, 'build.finished' => 0, 'build.busy' => 1 },
        { join => [ 'build' ]
        , order_by => [ 'machine' ]
        } ) ];
}


sub machines :Local Args(0) {
    my ($self, $c) = @_;
    my $machines = getMachines;
    my $idles = $c->model('DB::BuildSteps')->search(
            { stoptime => { '!=', undef } },
            { select => [ 'machine', { max => 'stoptime', -as => 'max_stoptime' }], group_by => "machine" });
    while (my $idle = $idles->next) {
        ${$machines}{$idle->machine}{'idle'} = $idle->max_stoptime;
    }
    $c->stash->{machines} = $machines;
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { finished => 0, 'me.busy' => 1, 'build.busy' => 1, },
        { join => [ 'build' ]
        , order_by => [ 'machine', 'stepnr' ]
        } ) ];
    $c->stash->{template} = 'machine-status.tt';
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
        my ($c, $controller, $action, @args) = @_;
        return $c->uri_for($c->controller($controller)->action_for($action), @args)->path;
    }

    sub channelUris {
        my ($c, $controller, $bindings) = @_;
        return
            ( uri_for($c, $controller, 'closure', $bindings, "*")
            , uri_for($c, $controller, 'manifest', $bindings)
            , uri_for($c, $controller, 'pkg', $bindings, "*")
            , uri_for($c, $controller, 'nixexprs', $bindings)
            , uri_for($c, $controller, 'channel_contents', $bindings)
            );
    }

    # Put actions that are expensive or not useful for indexing in
    # robots.txt.  Note: wildcards are not universally supported in
    # robots.txt, but apparently Google supports them.
    my @rules =
        ( uri_for($c, 'Build', 'deps', ["*"])
        , uri_for($c, 'Build', 'view_nixlog', ["*"], "*")
        , uri_for($c, 'Build', 'view_log', ["*"], "*")
        , uri_for($c, 'Build', 'view_log', ["*"])
        , uri_for($c, 'Build', 'download', ["*"], "*")
        , uri_for($c, 'Root', 'nar', [], "*")
        , uri_for($c, 'Root', 'status', [])
        , uri_for($c, 'Root', 'all', [])
        , uri_for($c, 'API', 'scmdiff', [])
        , uri_for($c, 'API', 'logdiff', [],"*", "*")
        , uri_for($c, 'Project', 'all', ["*"])
        , channelUris($c, 'Root', ["*"])
        , channelUris($c, 'Project', ["*", "*"])
        , channelUris($c, 'Jobset', ["*", "*", "*"])
        , channelUris($c, 'Job', ["*", "*", "*", "*"])
        , channelUris($c, 'Build', ["*"])
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

    if (defined $c->stash->{json}) {
        if (scalar @{$c->error}) {
            $c->stash->{json}->{error} = join "\n", @{$c->error};
            $c->clear_errors;
        }
        $c->forward('View::JSON');
    }

    elsif (scalar @{$c->error}) {
        $c->stash->{template} = 'error.tt';
        $c->stash->{errors} = $c->error;
        $c->response->status(500) if $c->response->status == 200;
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


sub nix_cache_info :Path('nix-cache-info') :Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('text/plain');
    $c->stash->{'plain'} = { data =>
        #"StoreDir: $Nix::Config::storeDir\n" . # FIXME
        "StoreDir: /nix/store\n" .
        "WantMassQuery: 0\n" .
        # Give Hydra binary caches a very low priority (lower than the
        # static binary cache http://nixos.org/binary-cache).
        "Priority: 100\n"
    };
    $c->forward('Hydra::View::Plain');
}


sub hashToPath {
    my ($c, $hash) = @_;
    die if length($hash) != 32;
    my $path = queryPathFromHashPart($hash);
    notFound($c, "Store path with hash ‘$hash’ does not exist.") unless $path;
    return $path;
}


sub narinfo :LocalRegex('^([a-z0-9]+).narinfo$') :Args(0) {
    my ($self, $c) = @_;
    my $hash = $c->req->captures->[0];
    $c->stash->{storePath} = hashToPath($c, $hash);
    $c->stash->{current_view} = 'NARInfo';
}


sub logo :Local {
    my ($self, $c) = @_;
    my $path = $ENV{"HYDRA_LOGO"} or die("Logo not set!");
    $c->serve_static_file($path);
}


sub evals :Local Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'evals.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $evals = $c->model('DB::JobsetEvals');

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $evals->search({hasnewbuilds => 1})->count;
    $c->stash->{evals} = getEvals($self, $c, $evals, ($page - 1) * $resultsPerPage, $resultsPerPage)
}


sub search :Local Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'search.tt';

    my $query = trim $c->request->params->{"query"};

    error($c, "Query is empty.") if $query eq "";
    error($c, "Invalid character in query.")
        unless $query =~ /^[a-zA-Z0-9_\-]+$/;

    $c->stash->{limit} = 500;

    $c->stash->{projects} = [ $c->model('DB::Projects')->search(
        { -and =>
            [ { -or => [ name => { ilike => "%$query%" }, displayName => { ilike => "%$query%" }, description => { ilike => "%$query%" } ] }
            , { hidden => 0 }
            ]
        },
        { order_by => ["name"] } ) ];

    $c->stash->{jobsets} = [ $c->model('DB::Jobsets')->search(
        { -and =>
            [ { -or => [ "me.name" => { ilike => "%$query%" }, "me.description" => { ilike => "%$query%" } ] }
            , { "project.hidden" => 0, "me.hidden" => 0 }
            ]
        },
        { order_by => ["project", "name"], join => ["project"] } ) ];

    $c->stash->{jobs} = [ $c->model('DB::Jobs')->search(
        { "me.name" => { ilike => "%$query%" }
        , "project.hidden" => 0
        , "jobset.hidden" => 0
        },
        { order_by => ["enabled_ desc", "project", "jobset", "name"], join => ["project", "jobset"]
        , "+select" => [\ "(project.enabled = 1 and jobset.enabled = 1 and exists (select 1 from Builds where project = project.name and jobset = jobset.name and job = me.name and iscurrent = 1)) enabled_"]
        , "+as" => ["enabled"]
        , rows => $c->stash->{limit} + 1
        } ) ];
}


1;

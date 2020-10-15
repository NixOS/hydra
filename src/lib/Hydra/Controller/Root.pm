package Hydra::Controller::Root;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::ListBuilds';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::View::TT;
use Digest::SHA1 qw(sha1_hex);
use Nix::Store;
use Nix::Config;
use Encode;
use File::Basename;
use JSON;
use List::MoreUtils qw{any};
use Net::Prometheus;
use IO::Handle;

# Put this controller at top-level.
__PACKAGE__->config->{namespace} = '';


sub noLoginNeeded {
  my ($c) = @_;

  my $hostname = $c->request->headers->header('X-Forwarded-For') || $c->request->hostname;
  my $readonly_ips = $c->config->{readonly_ips} // "";
  my $whitelisted = any { $_ eq $hostname } split(/,/, $readonly_ips);

  return $whitelisted ||
         $c->request->path eq "api/push-github" ||
         $c->request->path eq "google-login" ||
         $c->request->path eq "login" ||
         $c->request->path eq "logo" ||
         $c->request->path =~ /^static\//;
}


sub begin :Private {
    my ($self, $c, @args) = @_;

    $c->stash->{curUri} = $c->request->uri;
    $c->stash->{version} = $ENV{"HYDRA_RELEASE"} || "<devel>";
    $c->stash->{nixVersion} = $ENV{"NIX_RELEASE"} || "<devel>";
    $c->stash->{curTime} = time;
    $c->stash->{logo} = defined $c->config->{hydra_logo} ? "/logo" : "";
    $c->stash->{tracker} = $ENV{"HYDRA_TRACKER"};
    $c->stash->{flashMsg} = $c->flash->{flashMsg};
    $c->stash->{successMsg} = $c->flash->{successMsg};

    $c->stash->{isPrivateHydra} = $c->config->{private} // "0" ne "0";

    if ($c->stash->{isPrivateHydra} && ! noLoginNeeded($c)) {
        requireUser($c);
    }

    if (scalar(@args) == 0 || $args[0] ne "static") {
        $c->stash->{nrRunningBuilds} = dbh($c)->selectrow_array(
            "select count(distinct build) from buildsteps where busy != 0");
        $c->stash->{nrQueuedBuilds} = $c->model('DB::Builds')->search({ finished => 0 })->count();
    }

    # Gather the supported input types.
    $c->stash->{inputTypes} = {
        'string' => 'String value',
        'boolean' => 'Boolean',
        'nix' => 'Nix expression',
        'build' => 'Previous Hydra build',
        'sysbuild' => 'Previous Hydra build (same system)',
        'eval' => 'Previous Hydra evaluation'
    };
    $_->supportedInputTypes($c->stash->{inputTypes}) foreach @{$c->hydra_plugins};

    # XSRF protection: require POST requests to have the same origin.
    if ($c->req->method eq "POST" && $c->req->path ne "api/push-github") {
        my $referer = $c->req->header('Origin');
        $referer //= $c->req->header('Referer');
        my $base = $c->req->base;
        die unless $base =~ /\/$/;
        $referer .= "/";
        error($c, "POST requests should come from ‘$base’.")
            unless defined $referer && substr($referer, 0, length $base) eq $base;
    }

    $c->forward('deserialize');

    $c->stash->{params} = $c->request->data or $c->request->params;
    unless (defined $c->stash->{params} and %{$c->stash->{params}}) {
        $c->stash->{params} = $c->request->params;
    }

    # Set the Vary header to "Accept" to ensure that browsers don't
    # mix up HTML and JSON responses.
    $c->response->headers->header('Vary', 'Accept');
}


sub deserialize :ActionClass('Deserialize') { }


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'overview.tt';
    $c->stash->{projects} = [$c->model('DB::Projects')->search({}, {order_by => 'name'})];
    $c->stash->{newsItems} = [$c->model('DB::NewsItems')->search({}, { order_by => ['createtime DESC'], rows => 5 })];
    $self->status_ok($c,
        entity => $c->stash->{projects}
    );
}


sub queue :Local :Args(0) :ActionClass('REST') { }

sub queue_GET {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue.tt';
    $c->stash->{flashMsg} //= $c->flash->{buildMsg};
    $self->status_ok(
        $c,
        entity => [$c->model('DB::Builds')->search(
            { finished => 0 },
            { order_by => ["globalpriority desc", "id"],
            , columns => [@buildListColumns]
            })]
    );
}


sub queue_summary :Local :Path('queue-summary') :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue-summary.tt';

    $c->stash->{queued} = dbh($c)->selectall_arrayref(
        "select project, jobset, count(*) as queued, min(timestamp) as oldest, max(timestamp) as newest from Builds " .
        "where finished = 0 group by project, jobset order by queued desc",
        { Slice => {} });

    $c->stash->{systems} = dbh($c)->selectall_arrayref(
        "select system, count(*) as c from Builds where finished = 0 group by system order by c desc",
        { Slice => {} });
}


sub status :Local :Args(0) :ActionClass('REST') { }

sub status_GET {
    my ($self, $c) = @_;
    $self->status_ok(
        $c,
        entity => [$c->model('DB::Builds')->search(
            { "buildsteps.busy" => { '!=', 0 } },
            { order_by => ["globalpriority DESC", "id"],
              join => "buildsteps",
              columns => [@buildListColumns]
            })]
    );
}


sub queue_runner_status :Local :Path('queue-runner-status') :Args(0) :ActionClass('REST') { }

sub queue_runner_status_GET {
    my ($self, $c) = @_;

    #my $status = from_json($c->model('DB::SystemStatus')->find('queue-runner')->status);
    my $status = from_json(`hydra-queue-runner --status`);
    if ($?) { $status->{status} = "unknown"; }
    my $json = JSON->new->pretty()->canonical();

    $c->stash->{template} = 'queue-runner-status.tt';
    $c->stash->{status} = $json->encode($status);
    $self->status_ok($c, entity => $status);
}


sub machines :Local Args(0) {
    my ($self, $c) = @_;
    my $machines = getMachines;

    # Add entry for localhost.
    $machines->{''} //= {};
    delete $machines->{'localhost'};

    my $status = $c->model('DB::SystemStatus')->find("queue-runner");
    if ($status) {
        my $ms = decode_json($status->status)->{"machines"};
        foreach my $name (keys %{$ms}) {
            $name = "" if $name eq "localhost";
            $machines->{$name} //= {disabled => 1};
            $machines->{$name}->{nrStepsDone} = $ms->{$name}->{nrStepsDone};
            $machines->{$name}->{avgStepBuildTime} = $ms->{$name}->{avgStepBuildTime} // 0;
        }
    }

    $c->stash->{machines} = $machines;
    $c->stash->{steps} = dbh($c)->selectall_arrayref(
        "select build, stepnr, s.system as system, s.drvpath as drvpath, machine, s.starttime as starttime, project, jobset, job, s.busy as busy " .
        "from BuildSteps s join Builds b on s.build = b.id " .
        "where busy != 0 order by machine, stepnr",
        { Slice => {} });
    $c->stash->{template} = 'machine-status.tt';
    $self->status_ok($c, entity => $c->stash->{machines});
}

sub prometheus :Local Args(0) {
    my ($self, $c) = @_;
    my $machines = getMachines;

    my $client = Net::Prometheus->new;
    my $duration = $client->new_histogram(
        name => "hydra_machine_build_duration",
        help => "How long builds are taking per server. Note: counts are gauges, NOT counters.",
        labels => [ "machine" ],
        buckets => [
            60,
            600,
            1800,
            3600,
            7200,
            21600,
            43200,
            86400,
            172800,
            259200,
            345600,
            518400,
            604800,
            691200
        ]
    );

    my $steps = dbh($c)->selectall_arrayref(
        "select machine, s.starttime as starttime " .
        "from BuildSteps s join Builds b on s.build = b.id " .
        "where busy != 0 order by machine, stepnr",
        { Slice => {} });

    foreach my $step (@$steps) {
        my $name = $step->{machine} ? Hydra::View::TT->stripSSHUser(undef, $step->{machine}) : "";
        $name = "localhost" unless $name;
        $duration->labels($name)->observe(time - $step->{starttime});
    }

    $c->stash->{'plain'} = { data => $client->render };
    $c->forward('Hydra::View::Plain');
}


# Hydra::Base::Controller::ListBuilds needs this.
sub get_builds : Chained('/') PathPart('') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->stash->{allBuilds} = $c->model('DB::Builds');
    $c->stash->{latestSucceeded} = $c->model('DB')->resultset('LatestSucceeded');
    $c->stash->{channelBaseName} = "everything";
    $c->stash->{total} = $c->model('DB::NrBuilds')->find('finished')->count;
}


sub robots_txt : Path('robots.txt') {
    my ($self, $c) = @_;
    $c->stash->{'plain'} = { data => "User-agent: *\nDisallow: /*\n" };
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
            # FIXME: dunno why we need to do decode_utf8 here.
            $c->stash->{json}->{error} = join "\n", map { decode_utf8($_); } @{$c->error};
            $c->clear_errors;
        }
        $c->forward('View::JSON');
    }

    elsif (scalar @{$c->error}) {
        $c->stash->{resource} = { error => join "\n", @{$c->error} };
        if ($c->stash->{lazy}) {
            $c->response->headers->header('X-Hydra-Lazy', 'Yes');
            $c->stash->{template} = 'lazy_error.tt';
        }
        else {
            $c->stash->{template} = 'error.tt';
        }
        $c->stash->{errors} = $c->error;
        $c->response->status(500) if $c->response->status == 200;
        if ($c->response->status >= 300) {
            $c->stash->{httpStatus} =
                $c->response->status . " " . HTTP::Status::status_message($c->response->status);
        }
        $c->clear_errors;
    }

    $c->forward('serialize') if defined $c->stash->{resource};
}


sub serialize : ActionClass('Serialize') { }


sub nar :Local :Args(1) {
    my ($self, $c, $path) = @_;

    die if $path =~ /\//;

    if (isLocalStore) {
        $path = $Nix::Config::storeDir . "/$path";

        gone($c, "Path " . $path . " is no longer available.") unless isValidPath($path);

        $c->stash->{current_view} = 'NixNAR';
        $c->stash->{storePath} = $path;
    }

    elsif (isLocalBinaryCacheStore && getStoreUri =~ "^file:/+(.+)") {
        $c->response->content_type('application/x-nix-archive');

        $path = "/" . $1 . "/nar/$path";
        my $fh = new IO::Handle;
        open $fh, "<", $path;
        $c->response->body($fh);
    }

    else {
        notFound($c, "There is no binary cache here.");
    }
}


sub nix_cache_info :Path('nix-cache-info') :Args(0) {
    my ($self, $c) = @_;

    if (!isLocalStore && !isLocalBinaryCacheStore) {
        notFound($c, "There is no binary cache here.");
    }

    else {
        $c->response->content_type('text/plain');
        $c->stash->{plain}->{data} =
            "StoreDir: $Nix::Config::storeDir\n" .
            "WantMassQuery: 0\n" .
            # Give Hydra binary caches a very low priority (lower than the
            # static binary cache http://nixos.org/binary-cache).
            "Priority: 100\n";
        setCacheHeaders($c, 24 * 60 * 60);
        $c->forward('Hydra::View::Plain');
    }
}


sub narinfo :LocalRegex('^([a-z0-9]+).narinfo$') :Args(0) {
    my ($self, $c) = @_;

    my $hash = $c->req->captures->[0];

    die if length($hash) != 32;

    if (isLocalStore) {
        my $path = queryPathFromHashPart($hash);

        if (!$path) {
            $c->response->status(404);
            $c->response->content_type('text/plain');
            $c->stash->{plain}->{data} = "does not exist\n";
            $c->forward('Hydra::View::Plain');
            setCacheHeaders($c, 60 * 60);
            return;
        }

        $c->stash->{storePath} = $path;
        $c->forward('Hydra::View::NARInfo');
    }

    elsif (isLocalBinaryCacheStore && getStoreUri =~ "^file:/+(.+)") {
        $c->response->content_type('application/x-nix-archive');

        my $path = "/" . $1 . "/" . $hash . ".narinfo";
        my $fh = new IO::Handle;
        open $fh, "<", $path;
        $c->response->body($fh);
    }

    else {
        notFound($c, "There is no binary cache here.");
    }
}


sub logo :Local {
    my ($self, $c) = @_;
    my $path = $c->config->{hydra_logo} // die("Logo not set!");
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
    $c->stash->{evals} = getEvals($self, $c, $evals, ($page - 1) * $resultsPerPage, $resultsPerPage);

    $self->status_ok($c, entity => $c->stash->{evals});
}


sub steps :Local Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'steps.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{steps} = [ $c->model('DB::BuildSteps')->search(
        { starttime => { '!=', undef },
          stoptime => { '!=', undef }
        },
        { order_by => [ "stoptime desc" ],
          rows => $resultsPerPage,
          offset => ($page - 1) * $resultsPerPage
        }) ];

    $c->stash->{total} = approxTableSize($c, "IndexBuildStepsOnStopTime");
}


sub search :Local Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'search.tt';

    my $query = trim $c->request->params->{"query"};

    error($c, "Query is empty.") if $query eq "";
    error($c, "Invalid character in query.")
        unless $query =~ /^[a-zA-Z0-9_\-\/.]+$/;

    my $limit = trim $c->request->params->{"limit"};
    if ($limit eq "") {
        $c->stash->{limit} = 500;
    } else {
        $c->stash->{limit} = $limit;
    }

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

    $c->stash->{jobs} = [ $c->model('DB::Builds')->search(
        { "job" => { ilike => "%$query%" }
        , "project.hidden" => 0
        , "jobset.hidden" => 0
        , iscurrent => 1
        },
        { order_by => ["project", "jobset", "job"], join => ["project", "jobset"]
        , rows => $c->stash->{limit} + 1
        } )
    ];

    # Perform build search in separate queries to prevent seq scan on buildoutputs table.
    $c->stash->{builds} = [ $c->model('DB::Builds')->search(
        { "buildoutputs.path" => { ilike => "%$query%" } },
        { order_by => ["id desc"], join => ["buildoutputs"]
        , rows => $c->stash->{limit}
        } ) ];

    $c->stash->{buildsdrv} = [ $c->model('DB::Builds')->search(
        { "drvpath" => { ilike => "%$query%" } },
        { order_by => ["id desc"]
        , rows => $c->stash->{limit}
        } ) ];

    $c->stash->{resource} = { projects => $c->stash->{projects},
                              jobsets  => $c->stash->{jobsets},
                              builds  => $c->stash->{builds},
                              buildsdrv  => $c->stash->{buildsdrv} };
}

sub serveLogFile {
    my ($c, $logPath, $tail) = @_;
    $c->stash->{logPath} = $logPath;
    $c->stash->{tail} = $tail;
    $c->forward('Hydra::View::NixLog');
}

sub log :Local :Args(1) {
    my ($self, $c, $drvPath) = @_;

    $drvPath = "/nix/store/$drvPath";

    my $tail = $c->request->params->{"tail"};

    die if defined $tail && $tail !~ /^[0-9]+$/;

    my $logFile = findLog($c, $drvPath);

    if (defined $logFile) {
        serveLogFile($c, $logFile, $tail);
        return;
    }

    my $logPrefix = $c->config->{log_prefix};

    if (defined $logPrefix) {
        $c->res->redirect($logPrefix . "log/" . basename($drvPath));
    } else {
        notFound($c, "The build log of $drvPath is not available.");
    }
}

1;

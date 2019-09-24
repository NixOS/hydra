package Hydra::Controller::API;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Controller::Project;
use JSON;
use JSON::Any;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Text::Diff;
use File::Slurp;
use IPC::Run qw(run);


sub api : Chained('/') PathPart('api') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
}


sub buildToHash {
    my ($build) = @_;
    my $result = {
        id => $build->id,
        project => $build->get_column("project"),
        jobset => $build->get_column("jobset"),
        job => $build->get_column("job"),
        system => $build->system,
        nixname => $build->nixname,
        finished => $build->finished,
        timestamp => $build->timestamp
    };

    if($build->finished) {
        $result->{'buildstatus'} = $build->get_column("buildstatus");
    } else {
        $result->{'priority'} = $build->get_column("priority");
    }

    return $result;
};


sub latestbuilds : Chained('api') PathPart('latestbuilds') Args(0) {
    my ($self, $c) = @_;
    my $nr = $c->request->params->{nr};
    error($c, "Parameter not defined!") if !defined $nr;

    my $project = $c->request->params->{project};
    my $jobset = $c->request->params->{jobset};
    my $job = $c->request->params->{job};
    my $system = $c->request->params->{system};

    my $filter = {finished => 1};
    $filter->{project} = $project if ! $project eq "";
    $filter->{jobset} = $jobset if ! $jobset eq "";
    $filter->{job} = $job if !$job eq "";
    $filter->{system} = $system if !$system eq "";

    my @latest = $c->model('DB::Builds')->search($filter, {rows => $nr, order_by => ["id DESC"] });

    my @list;
    push @list, buildToHash($_) foreach @latest;

    $c->stash->{'plain'} = {
        data => scalar (JSON::Any->objToJson(\@list))
    };
    $c->forward('Hydra::View::Plain');
}


sub jobsetToHash {
    my ($jobset) = @_;
    return {
        project => $jobset->get_column('project'),
        name => $jobset->name,
        nrscheduled => $jobset->get_column("nrscheduled"),
        nrsucceeded => $jobset->get_column("nrsucceeded"),
        nrfailed => $jobset->get_column("nrfailed"),
        nrtotal => $jobset->get_column("nrtotal"),
        lastcheckedtime => $jobset->lastcheckedtime,
        starttime => $jobset->starttime,
        checkinterval => $jobset->checkinterval,
        triggertime => $jobset->triggertime,
        fetcherrormsg => $jobset->fetcherrormsg,
        errortime => $jobset->errortime,
        haserrormsg => $jobset->errormsg eq "" ? JSON::false : JSON::true
    };
}


sub jobsets : Chained('api') PathPart('jobsets') Args(0) {
    my ($self, $c) = @_;

    my $projectName = $c->request->params->{project};
    error($c, "Parameter 'project' not defined!") if !defined $projectName;

    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    my @jobsets = jobsetOverview($c, $project);

    my @list;
    push @list, jobsetToHash($_) foreach @jobsets;

    $c->stash->{'plain'} = {
        data => scalar (JSON::Any->objToJson(\@list))
    };
    $c->forward('Hydra::View::Plain');
}


sub queue : Chained('api') PathPart('queue') Args(0) {
    my ($self, $c) = @_;

    my $nr = $c->request->params->{nr};
    error($c, "Parameter not defined!") if !defined $nr;

    my @builds = $c->model('DB::Builds')->search({finished => 0}, {rows => $nr, order_by => ["priority DESC", "id"]});

    my @list;
    push @list, buildToHash($_) foreach @builds;

    $c->stash->{'plain'} = {
        data => scalar (JSON::Any->objToJson(\@list))
    };
    $c->forward('Hydra::View::Plain');
}


sub nrqueue : Chained('api') PathPart('nrqueue') Args(0) {
    my ($self, $c) = @_;
    my $nrQueuedBuilds = $c->model('DB::Builds')->search({finished => 0})->count();
    $c->stash->{'plain'} = {
        data => "$nrQueuedBuilds"
    };
    $c->forward('Hydra::View::Plain');
}


sub nrbuilds : Chained('api') PathPart('nrbuilds') Args(0) {
    my ($self, $c) = @_;
    my $nr = $c->request->params->{nr};
    my $period = $c->request->params->{period};

    error($c, "Parameter not defined!") if !defined $nr || !defined $period;
    my $base;

    my $project = $c->request->params->{project};
    my $jobset = $c->request->params->{jobset};
    my $job = $c->request->params->{job};
    my $system = $c->request->params->{system};

    my $filter = {finished => 1};
    $filter->{project} = $project if ! $project eq "";
    $filter->{jobset} = $jobset if ! $jobset eq "";
    $filter->{job} = $job if !$job eq "";
    $filter->{system} = $system if !$system eq "";

    $base = 60*60 if($period eq "hour");
    $base = 24*60*60 if($period eq "day");

    my @stats = $c->model('DB::Builds')->search($filter, {select => [{ count => "*" }], as => ["nr"], group_by => ["timestamp - timestamp % $base"], order_by => "timestamp - timestamp % $base DESC", rows => $nr});
    my @arr;
    push @arr, int($_->get_column("nr")) foreach @stats;
    @arr = reverse(@arr);

    $c->stash->{'plain'} = {
        data => scalar (JSON::Any->objToJson(\@arr))
    };
    $c->forward('Hydra::View::Plain');
}


sub scmdiff : Path('/api/scmdiff') Args(0) {
    my ($self, $c) = @_;

    my $uri = $c->request->params->{uri};
    my $type = $c->request->params->{type};
    my $rev1 = $c->request->params->{rev1};
    my $rev2 = $c->request->params->{rev2};

    die("invalid revisions: [$rev1] [$rev2]") if $rev1 !~ m/^[a-zA-Z0-9_.]+$/ || $rev2 !~ m/^[a-zA-Z0-9_.]+$/;

    # FIXME: injection danger.

    my $diff = "";
    if ($type eq "hg") {
        my $clonePath = getSCMCacheDir . "/hg/" . sha256_hex($uri);
        die "repository '$uri' is not in the SCM cache\n" if ! -d $clonePath;
        my $out;
        run(["hg", "log", "-R", $clonePath, "-r", "reverse($rev1::$rev2) and not($rev1)"], \undef, \$out)
            or die "hg log failed";
        $diff .= $out;
        run(["hg", "diff", "-R", $clonePath, "-r", "$rev1::$rev2"], \undef, \$out)
            or die "hg diff failed";
        $diff .= $out;
    } elsif ($type eq "git") {
        my $clonePath = getSCMCacheDir . "/git/" . sha256_hex($uri);
        die if ! -d $clonePath;
        $diff .= `(cd $clonePath; git log $rev1..$rev2)`;
        $diff .= `(cd $clonePath; git diff $rev1..$rev2)`;
    }

    $c->stash->{'plain'} = { data => (scalar $diff) || " " };
    $c->forward('Hydra::View::Plain');
}


sub triggerJobset {
    my ($self, $c, $jobset, $force) = @_;
    print STDERR "triggering jobset ", $jobset->get_column('project') . ":" . $jobset->name, "\n";
    txn_do($c->model('DB')->schema, sub {
        $jobset->update({ triggertime => time });
        $jobset->update({ forceeval => 1 }) if $force;
    });
    push @{$c->{stash}->{json}->{jobsetsTriggered}}, $jobset->get_column('project') . ":" . $jobset->name;
}


sub push : Chained('api') PathPart('push') Args(0) {
    my ($self, $c) = @_;

    $c->{stash}->{json}->{jobsetsTriggered} = [];

    my $force = exists $c->request->query_params->{force};
    my @jobsets = split /,/, ($c->request->query_params->{jobsets} // "");
    foreach my $s (@jobsets) {
        my ($p, $j) = parseJobsetName($s);
        my $jobset = $c->model('DB::Jobsets')->find($p, $j);
        next unless defined $jobset && ($force || ($jobset->project->enabled && $jobset->enabled));
        triggerJobset($self, $c, $jobset, $force);
    }

    my @repos = split /,/, ($c->request->query_params->{repos} // "");
    foreach my $r (@repos) {
        triggerJobset($self, $c, $_, $force) foreach $c->model('DB::Jobsets')->search(
            { 'project.enabled' => 1, 'me.enabled' => 1 },
            { join => 'project'
            , where => \ [ 'exists (select 1 from JobsetInputAlts where project = me.project and jobset = me.name and value = ?)', [ 'value', $r ] ]
            });
    }

    $self->status_ok(
        $c,
        entity => { jobsetsTriggered => $c->stash->{json}->{jobsetsTriggered} }
    );
}


sub push_github : Chained('api') PathPart('push-github') Args(0) {
    my ($self, $c) = @_;

    $c->{stash}->{json}->{jobsetsTriggered} = [];

    my $in = $c->request->{data};
    my $owner = $in->{repository}->{owner}->{name} or die;
    my $repo = $in->{repository}->{name} or die;
    print STDERR "got push from GitHub repository $owner/$repo\n";

    triggerJobset($self, $c, $_, 0) foreach $c->model('DB::Jobsets')->search(
        { 'project.enabled' => 1, 'me.enabled' => 1 },
        { join => 'project'
        , where => \ [ 'exists (select 1 from JobsetInputAlts where project = me.project and jobset = me.name and value like ?)', [ 'value', "%github.com%$owner/$repo%" ] ]
        });
    $c->response->body("");
}



1;

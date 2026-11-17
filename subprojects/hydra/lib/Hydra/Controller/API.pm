package Hydra::Controller::API;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::REST';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Exec;
use Hydra::Helper::RequestParams qw(requestParams Integer matching oneOf record);
use Types::Standard qw(Str);
use Hydra::Controller::Project;
use JSON::MaybeXS;
use DateTime;
use Digest::SHA qw(sha256_hex);
use Text::Diff;
use IPC::Run qw(run);
use Digest::SHA qw(hmac_sha256_hex);
use String::Compare::ConstantTime qw(equals);
use IPC::Run3;


sub api : Chained('/') PathPart('api') CaptureArgs(0) {
    my ($self, $c) = @_;
    $c->response->content_type('application/json');
}


sub buildToHash {
    my ($build) = @_;
    my $result = {
        id => $build->id,
        project => $build->jobset->get_column("project"),
        jobset => $build->jobset->get_column("name"),
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


# The filters `latestbuilds` and `nrbuilds` take.
# Any non-empty string, rather than the name patterns, which only creation
# enforces: these look up existing rows, whose names may predate them.
my %buildFilterParams = (
    project => matching(qr/.+/s, "The project filter must be a single name."),
    jobset => matching(qr/.+/s, "The jobset filter must be a single name."),
    job => matching(qr/.+/s, "The job filter must be a single name."),
    system => matching(qr/.+/s, "The system filter must be a single name."),
);

# Applies the filters in `%buildFilterParams` that `$p` has.
sub buildFilter {
    my ($p) = @_;
    my $filter = {finished => 1};
    $filter->{"jobset.project"} = $p->{project} if defined $p->{project};
    $filter->{"jobset.name"} = $p->{jobset} if defined $p->{jobset};
    $filter->{job} = $p->{job} if defined $p->{job};
    $filter->{system} = $p->{system} if defined $p->{system};
    return $filter;
}

sub latestbuilds : Chained('api') PathPart('latestbuilds') Args(0) {
    my ($self, $c) = @_;
    my $p = requestParams($c, {
        %buildFilterParams,
        nr => Integer,
    }, from => $c->request->params);
    error($c, "Parameter not defined!") if !defined $p->{nr};

    my @latest = $c->model('DB::Builds')->search(
        buildFilter($p),
        {
            rows => $p->{nr},
            order_by => ["id DESC"],
            join => [ "jobset" ]
        });

    my @list;
    push @list, buildToHash($_) foreach @latest;

    $c->stash->{'plain'} = {
        data => scalar (encode_json(\@list))
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
        haserrormsg => defined($jobset->errormsg) && $jobset->errormsg ne "" ? JSON::MaybeXS::true : JSON::MaybeXS::false
    };
}


sub jobsets : Chained('api') PathPart('jobsets') Args(0) {
    my ($self, $c) = @_;

    my $projectName = requestParams($c, { project => Str }, from => $c->request->params)->{project};
    error($c, "Parameter 'project' not defined!") if !defined $projectName;

    my $project = $c->model('DB::Projects')->find($projectName)
        or notFound($c, "Project $projectName doesn't exist.");

    my @jobsets = jobsetOverview($c, $project);

    my @list;
    push @list, jobsetToHash($_) foreach @jobsets;

    $c->stash->{'plain'} = {
        data => scalar (encode_json(\@list))
    };
    $c->forward('Hydra::View::Plain');
}


sub queue : Chained('api') PathPart('queue') Args(0) {
    my ($self, $c) = @_;

    my $nr = requestParams($c, { nr => Integer }, from => $c->request->params)->{nr};
    error($c, "Parameter not defined!") if !defined $nr;

    my @builds =$c->model('DB::Builds')->search({finished => 0}, {rows => $nr, order_by => ["priority DESC", "id"]});

    my @list;
    push @list, buildToHash($_) foreach @builds;

    $c->stash->{'plain'} = {
        data => scalar (encode_json(\@list))
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
    my $p = requestParams($c, {
        %buildFilterParams,
        nr => Integer,
        period => oneOf([qw(hour day)], sub { "Invalid period ‘$_’; valid periods: ‘hour’ and ‘day’." }),
    }, from => $c->request->params);

    error($c, "Parameter not defined!") if !defined $p->{nr} || !defined $p->{period};
    my $base = $p->{period} eq "hour" ? 60*60 : 24*60*60;

    my @stats = $c->model('DB::Builds')->search(
        buildFilter($p),
        {
            select => [{ count => "*" }],
            as => ["nr"],
            group_by => ["timestamp - timestamp % $base"],
            order_by => "timestamp - timestamp % $base DESC",
            rows => $p->{nr},
            join => [ "jobset" ]
        }
    );
    my @arr;
    push @arr, int($_->get_column("nr")) foreach @stats;
    @arr = reverse(@arr);

    $c->stash->{'plain'} = {
        data => scalar (encode_json(\@arr))
    };
    $c->forward('Hydra::View::Plain');
}


sub scmdiff : Path('/api/scmdiff') Args(0) {
    my ($self, $c) = @_;

    my $p = requestParams($c, {
        uri => Str,
        type => Str,
        rev1 => Str,
        rev2 => Str,
    }, from => $c->request->params);
    my $uri = $p->{uri};
    my $type = $p->{type};
    my $rev1 = $p->{rev1};
    my $rev2 = $p->{rev2};

    die("invalid revisions: [$rev1] [$rev2]") if $rev1 !~ m/^[a-zA-Z0-9_.]+$/ || $rev2 !~ m/^[a-zA-Z0-9_.]+$/;

    # FIXME: injection danger.

    my $diff = "";
    if ($type eq "hg") {
        my $clonePath = getSCMCacheDir . "/hg/" . sha256_hex($uri);
        die "repository '$uri' is not in the SCM cache\n" if ! -d $clonePath;
        my $out;
        run([program("hg"), "log", "-R", $clonePath, "-r", "reverse($rev1::$rev2) and not($rev1)"], \undef, \$out)
            or die "hg log failed";
        $diff .= $out;
        run([program("hg"), "diff", "-R", $clonePath, "-r", "$rev1::$rev2"], \undef, \$out)
            or die "hg diff failed";
        $diff .= $out;
    } elsif ($type eq "git") {
        my $clonePath = getSCMCacheDir . "/git/" . sha256_hex($uri);
        die if ! -d $clonePath;
        my ($stdout1, $stderr1);
        run3([program("git"), '--git-dir', '.git', '-C', $clonePath, 'log', "$rev1..$rev2"], \undef, \$stdout1, \$stderr1);
        $diff .= $stdout1 if $? == 0;

        my ($stdout2, $stderr2);
        run3([program("git"), '--git-dir', '.git', '-C', $clonePath, 'diff', "$rev1..$rev2"], \undef, \$stdout2, \$stderr2);
        $diff .= $stdout2 if $? == 0;
    }

    $c->stash->{'plain'} = { data => (scalar $diff) || " " };
    $c->forward('Hydra::View::Plain');
}


sub triggerJobset {
    my ($self, $c, $jobset, $force) = @_;
    print STDERR "triggering jobset ", $jobset->get_column('project') . ":" . $jobset->name, "\n";
    $c->model('DB')->schema->txn_do(sub {
        $jobset->update({ triggertime => time });
        $jobset->update({ forceeval => 1 }) if $force;
    });
    push @{$c->{stash}->{json}->{jobsetsTriggered}}, $jobset->get_column('project') . ":" . $jobset->name;
}


sub push : Chained('api') PathPart('push') Args(0) {
    my ($self, $c) = @_;

    requirePost($c);

    $c->{stash}->{json}->{jobsetsTriggered} = [];

    my $q = requestParams($c, {
        force => Str,
        jobsets => Str,
        repos => Str,
    }, from => $c->request->query_params);
    # A bare `?force` counts too.
    my $force = defined $q->{force};
    my @jobsets = split /,/, ($q->{jobsets} // "");
    foreach my $s (@jobsets) {
        my ($p, $j) = parseJobsetName($s);
        my $jobset = $c->model('DB::Jobsets')->find($p, $j);
        requireEvalJobsetPrivileges($c, $jobset->project);
        next unless defined $jobset && ($force || ($jobset->project->enabled && $jobset->enabled));
        triggerJobset($self, $c, $jobset, $force);
    }

    my @repos = split /,/, ($q->{repos} // "");
    foreach my $r (@repos) {
        my @jobsets = $c->model('DB::Jobsets')->search(
            { 'project.enabled' => 1, 'me.enabled' => 1 },
            {
                join => 'project',
                where => \ [ 'exists (select 1 from JobsetInputAlts where project = me.project and jobset = me.name and value = ?)', [ 'value', $r ] ],
                order_by => 'me.id DESC'
            });
        foreach my $jobset (@jobsets) {
            requireEvalJobsetPrivileges($c, $jobset->project);
            triggerJobset($self, $c, $jobset, $force)
        }
    }

    $self->status_ok(
        $c,
        entity => { jobsetsTriggered => $c->stash->{json}->{jobsetsTriggered} }
    );
}

sub verifyWebhookSignature {
    my ($c, $platform, $header_name, $signature_prefix) = @_;

    # Get secrets from config
    my $webhook_config = $c->config->{webhooks} // {};
    my $platform_config = $webhook_config->{$platform} // {};
    my $secrets = $platform_config->{secret};

    # Normalize to array
    $secrets = [] unless defined $secrets;
    $secrets = [$secrets] unless ref($secrets) eq 'ARRAY';

    # Trim whitespace from secrets
    my @secrets = grep { defined && length } map { s/^\s+|\s+$//gr } @$secrets;

    if (@secrets) {
        my $signature = $c->request->header($header_name);

        if (!$signature) {
            $c->log->warn("Webhook authentication failed for $platform: Missing signature from IP " . $c->request->address);
            $c->response->status(401);
            $c->stash->{json} = { error => "Missing webhook signature" };
            $c->forward('View::JSON');
            return 0;
        }

        # Get the raw body content from the buffered PSGI input
        # For JSON requests, Catalyst will have already read and buffered the body
        my $input = $c->request->env->{'psgi.input'};
        $input->seek(0, 0);
        local $/;
        my $payload = <$input>;
        $input->seek(0, 0);  # Reset for any other consumers

        unless (defined $payload && length $payload) {
            $c->log->warn("Webhook authentication failed for $platform: Empty request body from IP " . $c->request->address);
            $c->response->status(400);
            $c->stash->{json} = { error => "Empty request body" };
            $c->forward('View::JSON');
            return 0;
        }

        my $valid = 0;
        for my $secret (@secrets) {
            my $expected = $signature_prefix . hmac_sha256_hex($payload, $secret);
            if (equals($signature, $expected)) {
                $valid = 1;
                last;
            }
        }

        if (!$valid) {
            $c->log->warn("Webhook authentication failed for $platform: Invalid signature from IP " . $c->request->address);
            $c->response->status(401);
            $c->stash->{json} = { error => "Invalid webhook signature" };
            $c->forward('View::JSON');
            return 0;
        }

        return 1;
    } else {
        $c->log->warn("Webhook authentication failed for $platform: Unable to validate signature from IP " . $c->request->address . " because no secrets are configured");
        $c->response->status(401);
        $c->stash->{json} = { error => "Invalid webhook signature" };
        $c->forward('View::JSON');
        return 0;
    }
}

sub push_github : Chained('api') PathPart('push-github') Args(0) {
    my ($self, $c) = @_;

    $c->{stash}->{json}->{jobsetsTriggered} = [];

    return unless verifyWebhookSignature($c, 'github', 'X-Hub-Signature-256', 'sha256=');

    my $p = requestParams($c, {
        repository => record(
            required => {
                name => Str,
            },
            optional => {
                owner => record(optional => {
                    name => Str,
                    login => Str,
                }),
            },
        ),
    }, from => $c->request->data // {}, quiet => 1);
    my $repository = $p->{repository} // badRequest($c, "The payload has no repository.");
    my $owner = $repository->{owner}->{name} // $repository->{owner}->{login}
        // badRequest($c, "The payload's repository has no owner.");
    my $repo = $repository->{name};
    print STDERR "got push from GitHub repository $owner/$repo\n";

    triggerJobset($self, $c, $_, 0) foreach $c->model('DB::Jobsets')->search(
        { 'project.enabled' => 1, 'me.enabled' => 1 },
        { join => 'project'
        , where => \ [ 'me.flake like ? or exists (select 1 from JobsetInputAlts where project = me.project and jobset = me.name and value like ?)', [ 'flake', "%github%$owner/$repo%"], [ 'value', "%github.com%$owner/$repo%" ] ]
        });
    $c->response->body("");
}

sub push_gitea : Chained('api') PathPart('push-gitea') Args(0) {
    my ($self, $c) = @_;

    $c->{stash}->{json}->{jobsetsTriggered} = [];

    # Note: Gitea doesn't use sha256= prefix
    return unless verifyWebhookSignature($c, 'gitea', 'X-Gitea-Signature', '');

    my $p = requestParams($c, {
        repository => record(required => {
            clone_url => Str,
        }),
    }, from => $c->request->data // {}, quiet => 1);
    my $repository = $p->{repository} // badRequest($c, "The payload has no repository.");
    my $url = $repository->{clone_url};
    $url =~ s/.git$//;
    print STDERR "got push from Gitea repository $url\n";

    triggerJobset($self, $c, $_, 0) foreach $c->model('DB::Jobsets')->search(
        { 'project.enabled' => 1, 'me.enabled' => 1 },
        { join => 'project'
        , where => \ [ 'me.flake like ? or exists (select 1 from JobsetInputAlts where project = me.project and jobset = me.name and value like ?)', [ 'flake', "%$url%"], [ 'value', "%$url%" ] ]
        });
    $c->response->body("");
}


1;

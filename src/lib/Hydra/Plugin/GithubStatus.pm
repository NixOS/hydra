package Hydra::Plugin::GithubStatus;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use List::Util qw(max);
use String::Interpolate qw(safe_interpolate);

=head1 NAME

GithubStatus - hydra-notify plugin for sending GitHub statuses

=head1 DESCRIPTION

This plugin sends GitHub statuses
L<https://developer.github.com/v3/repos/statuses/>, a mechanism that allows
external services to mark commits with a state, which is then reflected in pull
requests involving those commits. Each status consists of a state (C<error>,
C<failure>, C<pending>, or C<success>), a context, an optional description, and
an optional target URL. The context is the text shown on GitHub's PR page,
followed by the description (if present), and a "Details" link which points to
the given target URL.

=head1 CONFIGURATION

The module is configured using the C<githubstatus> block in Hydra's config file.
There can be multiple such blocks in the config file, and each of them will be
used (thus, a duplicated entry will result in two status notifications being
sent).

The following entries are recognized in the C<githubstatus> block:

=over 4

=item jobs

A pattern for job names. All builds whose job name matches this pattern will
emit a GitHub status notification. The pattern will match the whole name, thus
leaving this field empty will result in no notifications being sent. To match on
all builds, use C<.*>.

=item context

(Optional) A context to use. If not given, a context will be deduced based on
the name of the job, and other parameters.

If given, a status notification will be emitted for every applicable job's
build, using the same context, resulting in overwrites. For example, if there
are two jobs for a PR, one build failing and another succeeding, and C<context>
is set, the final state shown by GitHub on PR's page will depend on which build
finished last.

The best is not to provide it.

=item description

(Optional) A description to use. If not provided, one will be constructed
including the build number and the job name.

=item inputs

A list of L<jobset inputs|https://nixos.org/hydra/manual/#idm140737319784192>
to consult to find the commit hash. As GitHub's statuses are per commit, not per
PR, this is needed to correctly route the notification.

=item excludeBuildFromContext

A integer indicating whether the build number should be appended to the
generated context, if L</context> is not provided. If 0 (the default value) the
build number will be appended. Any other value results in no build number
trailing the generated context.

=item useShortContext

An integer indicating whether Hydra should emit a short context if L</context> is
not provided. If 0 (the default value), the Hydra emits the default, long
context.

The long context begins with C<continuous-integration/hydra:>, followed by the
job name, and possibly the build number (if L</excludeBuildFromContext> is
unset).

The short context begins with C<hydra:> followed by the job name filtered from
any PR information. The GithubPulls plugin generates names for the job embedding the
PR number, as in C<repo.pr-1234>, which will be in the short context transformed
to just C<repo>.

=item jobNameCapture

(Optional) A Perl regex to be used to transform the job's name for use in
L</useShortContext>. If omitted, defaults to C<\.pr-\d+:>. This value is used in
conjuction with L</jobNameReplacement> and may contain capture groups, if they
are used in L</jobNameReplacement>.

=item jobNameReplacement

(Optional) A replacement text used to transform the job's name for use in
L</useShortContext>. If omitted, defaults to C<:>.

For example, the following configuration:

    <githubstatus>
    jobNameCapture = :([^:]+)\.pr-\d+:
    jobNameReplacement = -$1:
    </githubstatus>

Would result in renaming C<project:jobset.pr-1234:job1> to
C<project-jobset:job1>.

=item authorization

(Optional) Authorization token to be used for sending the notifications, in the
form C<token: ACTUAL_TOKEN_VALUE>. If omitted, C<github_authorization> from the
main config will be used.

=back

=head2 GitHub Enterprise

This plugin supports GitHub Enterprise through reading the global, optional
configuration option C<github_endpoint>. If omitted, defaults to
C<https://api.github.com>. For GitHub Enterprise, the API endpoint usually looks
like C<https://hostname/api/v3>.

=cut

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{githubstatus};
}

# Returns a list of "githubstatus" objects defined in the Hydra config.
# If there are none, this plugin is considered inactive.
# See module header for values that can appear in the config.
sub pluginConfig {
    my ($self) = @_;
    my $cfg = $self->{config}->{githubstatus};
    return defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();
}

sub toGithubState {
    my ($buildStatus) = @_;
    if ($buildStatus == 0) {
        return "success";
    } elsif ($buildStatus == 3 || $buildStatus == 4 || $buildStatus == 8 || $buildStatus == 10 || $buildStatus == 11) {
        return "error";
    } else {
        return "failure";
    }
}

# Turns build info into a context object for GitHub. This is the info that shows up
# in the build status section at the bottom of the PR page.
# It includes:
#   * status - success, error, or failure.
#   * job name - hydra:dfinity-ci-build:...
#     (in most cases, you can use CatalystUtils::showJobName to produce this.)
#   * short description - "Hydra build #12345 of ..."
#   * a link - we should link to the build page on Hydra if one is available.
#
# `conf` is a hashref that comes from `pluginConfig`.
# `jobName` is the full job string, like "dfinity-ci-build:hydra:test.api.x86_64-linux"
# `buildId` is a hydra build ID. It can be empty (for example, for an evaluation failure, there will be no job ID)
sub getContext {
    my ($self, $conf, $jobName, $buildId) = @_;
    my $jobNameCaptureString = $conf->{jobNameCapture} // '\.pr-\d+:';
    my $jobNameCapture = qr($jobNameCaptureString);
    my $jobNameReplacement = $conf->{jobNameReplacement} // ':';

    my $contextTrailer = $conf->{excludeBuildFromContext} ? "" : (":" . $buildId);
    my $githubJobName = $jobName =~ s/$jobNameCapture/safe_interpolate($jobNameReplacement)/reg;
    my $extendedContext = $conf->{context} // "continuous-integration/hydra:" . $jobName . $contextTrailer;
    my $shortContext = $conf->{context} // "hydra:" . $githubJobName . $contextTrailer;
    return $conf->{useShortContext} ? $shortContext : $extendedContext;
}

sub postStatus {
    my ($self, $conf, $jobName, $evalInputs, $body) = @_;

    my $ua = LWP::UserAgent->new();
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";
    my $githubEndpoint = $self->{config}->{'github_endpoint'} // "https://api.github.com";

    return unless $jobName =~ /^$conf->{jobs}$/;
    print STDERR "GithubStatus_Debug job name $jobName\n";
    my $body = encode_json($body);

    my $inputs_cfg = $conf->{inputs};
    my @inputs = defined $inputs_cfg ? ref $inputs_cfg eq "ARRAY" ? @$inputs_cfg : ($inputs_cfg) : ();
    my %seen = map { $_ => {} } @inputs;
    my $dry_run = defined $conf->{test};

    foreach my $evalInput (@$evalInputs) {
        if (eval { $evalInput->isa("DBIx::Class::Row") }) {
            # convert row to hashref so we can index it below
            $evalInput = {$evalInput->get_inflated_columns};
        }
        foreach my $inputName (@inputs) {
            my ($i) = grep {$_->{name} eq $inputName} $evalInput;
            next unless defined $i;
            my $uri = $i->{uri};
            my $rev = $i->{revision};
            my $key = $uri . "-" . $rev;
            next if exists $seen{$inputName}->{$key};

            $seen{$inputName}->{$key} = 1;
            $uri =~ m![:/]([^/]+)/([^/]+?)(?:.git)?$!;
            my $owner = $1;
            my $repo = $2;
            my $url = "${githubEndpoint}/repos/$owner/$repo/statuses/$rev";

            print STDERR "GithubStatus_Debug POSTing to '", $url, "'\n";
            print STDERR ">> $body\n";
            next if $dry_run;

            my $req = HTTP::Request->new('POST', $url);
            $req->header('Content-Type' => 'application/json');
            $req->header('Accept' => 'application/vnd.github.v3+json');
            $req->header('Authorization' => ($self->{config}->{github_authorization}->{$owner} // $conf->{authorization}));
            $req->content($body);
            my $res = $ua->request($req);

            my $limit = $res->header("X-RateLimit-Limit");
            my $limitRemaining = $res->header("X-RateLimit-Remaining");
            my $limitReset = $res->header("X-RateLimit-Reset");
            my $now = time();
            my $diff = $limitReset - $now;
            my $delay = (($limit - $limitRemaining) / $diff) * 5;
            if ($limitRemaining < 1000) {
                $delay = max(1, $delay);
            }
            if ($limitRemaining < 2000) {
                print STDERR "GithubStatus ratelimit $limitRemaining/$limit, resets in $diff, sleeping $delay\n";
                sleep $delay;
            } else {
                print STDERR "GithubStatus ratelimit $limitRemaining/$limit, resets in $diff\n";
            }
        }
    }
}

sub common {
    my ($self, $build, $dependents, $finished) = @_;
    my $cfg = $self->{config}->{githubstatus};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";
    my $githubEndpoint = $self->{config}->{'github_endpoint'} // "https://api.github.com";

    # Find matching configs
    foreach my $b ($build, @{$dependents}) {
        my $jobName = showJobName $b;
        my $latestEval = $build->jobsetevals->first;

        foreach my $conf (@config) {
            next if !$finished && $b->finished == 1;
            $self->postStatus($conf, $jobName, [$latestEval->jobsetevalinputs->all], {
                state => $finished ? toGithubState($b->buildstatus) : "pending",
                target_url => "$baseurl/build/".$b->id,
                description => $conf->{description} // "Hydra build #" . $b->id . " of $jobName",
                context => $self->getContext($conf, $jobName, $b->id)
            });
        }
    }
}

sub notifyFromEval {
    my ($self, $eval, $project, $jobset, $job) = @_;

    my $jobName = "$project:$jobset:$job";
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    foreach my $conf ($self->pluginConfig()) {
        postStatus($self, $conf, $jobName, [$eval->jobsetevalinputs->all], {
            state => "error",
            target_url => "$baseurl/jobset/$project/$jobset#tabs-errors",
            description => $conf->{description} // "Failed to evaluate",
            context => $self->getContext($conf, $jobName, ""),
        });
    }
}

sub buildQueued {
    common(@_, [], 0);
}

sub buildStarted {
    common(@_, [], 0);
}

sub buildFinished {
    common(@_, 1);
}

sub jobEvalFailed {
    notifyFromEval(@_);
}

sub evalFailed {
    my ($self, $project, $jobset, $inputs) = @_;
    my $jobName = "$project:$jobset";
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";
    foreach my $conf ($self->pluginConfig()) {
        postStatus($self, $conf, $jobName, $inputs, {
            state => "error",
            target_url => "$baseurl/jobset/$project/$jobset#tabs-errors",
            description => $conf->{description} // "Failed to evaluate",
            context => $self->getContext($conf, $jobName, "")
        });
    }
}

sub evalFinished {
    my ($self, $eval) = @_;
    my $project = $eval->get_column('project');
    my $jobset = $eval->get_column('jobset');
    my $jobName = "$project:$jobset";
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";
    foreach my $conf ($self->pluginConfig()) {
        postStatus($self, $conf, $jobName, [$eval->jobsetevalinputs->all], {
            state => "success",
            target_url => "$baseurl/jobset/$project/$jobset",
            description => $conf->{description} // "Evaluated successfully",
            context => $self->getContext($conf, $jobName, "")
        });
    }
}

1;

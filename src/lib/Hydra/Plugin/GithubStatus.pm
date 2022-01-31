package Hydra::Plugin::GithubStatus;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON::MaybeXS;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use List::Util qw(max);

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{githubstatus};
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

sub common {
    my ($self, $topbuild, $dependents, $finished, $cachedEval) = @_;
    my $cfg = $self->{config}->{githubstatus};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Find matching configs
    foreach my $build ($topbuild, @{$dependents}) {
        my $jobName = showJobName $build;
        my $evals = $topbuild->jobsetevals;
        my $ua = LWP::UserAgent->new();

        foreach my $conf (@config) {
            next unless $jobName =~ /^$conf->{jobs}$/;
            # Don't send out "pending" status updates if the build is already finished
            next if !$finished && $build->finished == 1;

            my $contextTrailer = $conf->{excludeBuildFromContext} ? "" : (":" . $build->id);
            my $github_job_name = $jobName =~ s/-pr-\d+//r;
            my $extendedContext = $conf->{context} // "continuous-integration/hydra:" . $jobName . $contextTrailer;
            my $shortContext = $conf->{context} // "ci/hydra:" . $github_job_name . $contextTrailer;
            my $context = $conf->{useShortContext} ? $shortContext : $extendedContext;
            my $body = encode_json(
                {
                    state => $finished ? toGithubState($build->buildstatus) : "pending",
                    target_url => "$baseurl/build/" . $build->id,
                    description => $conf->{description} // "Hydra build #" . $build->id . " of $jobName",
                    context => $context
                });
            my $inputs_cfg = $conf->{inputs};
            my @inputs = defined $inputs_cfg ? ref $inputs_cfg eq "ARRAY" ? @$inputs_cfg : ($inputs_cfg) : ();
            my %seen = map { $_ => {} } @inputs;
            while (my $eval = $evals->next) {
                if (defined($cachedEval) && $cachedEval->id != $eval->id) {
                    next;
                }

                my $sendStatus = sub {
                    my ($input, $owner, $repo, $rev) = @_;

                    my $key = $owner . "-" . $repo . "-" . $rev;
                    return if exists $seen{$input}->{$key};
                    $seen{$input}->{$key} = 1;

                    my $url = "https://api.github.com/repos/$owner/$repo/statuses/$rev";
                    my $req = HTTP::Request->new('POST', $url);
                    $req->header('Content-Type' => 'application/json');
                    $req->header('Accept' => 'application/vnd.github.v3+json');
                    $req->header('Authorization' => ($self->{config}->{github_authorization}->{$owner} // $conf->{authorization}));
                    $req->content($body);
                    my $res = $ua->request($req);
                    print STDERR $res->status_line, ": ", $res->decoded_content, "\n" unless $res->is_success;
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
                };

                if (defined $eval->flake) {
                    my $fl = $eval->flake;
                    print STDERR "Flake is $fl\n";
                    if ($eval->flake =~ m!github:([^/]+)/([^/]+)/([[:xdigit:]]{40})$! or $eval->flake =~ m!git\+ssh://git\@github.com/([^/]+)/([^/]+)\?.*rev=([[:xdigit:]]{40})$!) {
                        $sendStatus->("src", $1, $2, $3);
                    } else {
                        print STDERR "Can't parse flake, skipping GitHub status update\n";
                    }
                } else {
                    foreach my $input (@inputs) {
                        my $i = $eval->jobsetevalinputs->find({ name => $input, altnr => 0 });
                        if (! defined $i) {
                            print STDERR "Evaluation $eval doesn't have input $input\n";
                        }
                        next unless defined $i;
                        my $uri = $i->uri;
                        my $rev = $i->revision;
                        $uri =~ m![:/]([^/]+)/([^/]+?)(?:.git)?$!;
                        $sendStatus->($input, $1, $2, $rev);
                    }
                }
            }
        }
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

sub cachedBuildQueued {
    my ($self, $evaluation, $build) = @_;
    common($self, $build, [], 0, $evaluation);
}

sub cachedBuildFinished {
    my ($self, $evaluation, $build) = @_;
    common($self, $build, [], 1, $evaluation);
}

1;

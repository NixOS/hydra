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

# Hosts compare exactly. The port stays for HTTP(S) because we need it to get to the API.
sub normalizeHost {
    my ($scheme, $host) = @_;
    $host =~ s/:\d+$// unless $scheme =~ /^https?$/;
    return $host;
}

sub apiBase {
    my ($host) = @_;
    return $host eq "github.com" ? "https://api.github.com" : "https://$host/api/v3";
}

# (HOST, OWNER, REPO, REV) of a locked flake, or () for one we don't know:
#   github:OWNER/REPO/REV[?...&host=HOST&...]
#   git+(https|ssh)://[USER@]HOST[:PORT]/OWNER/REPO[.git]?...&rev=REV&...
sub parseFlakeRef {
    my ($flake) = @_;
    if ($flake =~ m!^github:([^/?]+)/([^/?]+)/([[:xdigit:]]{40})(?:\?(.*))?$!) {
        my ($owner, $repo, $rev, $query) = ($1, $2, $3, $4 // "");
        my ($host) = $query =~ m!(?:^|&)host=([^&]+)!;
        return ($host // "github.com", $owner, $repo, $rev);
    }
    if ($flake =~ m!^git\+(https|ssh)://(?:[^@/]+\@)?([^/?]+)/([^/?]+)/([^/?]+?)(?:\.git)?\?(.*)$!) {
        my ($scheme, $host, $owner, $repo, $query) = ($1, $2, $3, $4, $5);
        my ($rev) = $query =~ m!(?:^|&)rev=([[:xdigit:]]{40})(?:&|$)!;
        return defined $rev ? (normalizeHost($scheme, $host), $owner, $repo, $rev) : ();
    }
    return ();
}

# (HOST, OWNER, REPO) of a git input's URI, or () for one we don't know:
#   SCHEME://[USER@]HOST[:PORT]/OWNER/REPO[.git] or [USER@]HOST:OWNER/REPO[.git]
sub parseRepoUri {
    my ($uri) = @_;
    if ($uri =~ m!^([a-z][a-z0-9+.-]*)://(?:[^@/]+\@)?([^/]+)/([^/]+)/([^/]+?)(?:\.git)?/?$!) {
        return (normalizeHost($1, $2), $3, $4);
    }
    if ($uri =~ m!^(?:[^@/]+\@)?([^/:]+):([^/]+)/([^/]+?)(?:\.git)?/?$!) {
        return ($1, $2, $3);
    }
    return ();
}

sub common {
    my ($self, $topbuild, $dependents, $finished, $cachedEval) = @_;
    my $cfg = $self->{config}->{githubstatus};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();
    my $baseurl = $self->{config}->{'base_uri'} || "http://localhost:3000";

    # Find matching configs
    foreach my $build ($topbuild, @{$dependents}) {
        my $jobName = showJobName $build;
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

            # Statuses and the token only go to this host.
            my $host = $conf->{host} || "github.com";
            my $apibase = apiBase($host);

            # Each config block should get a fresh jobsetevals.
            my $evals = $topbuild->jobsetevals;
            while (my $eval = $evals->next) {
                if (defined($cachedEval) && $cachedEval->id != $eval->id) {
                    next;
                }

                my $sendStatus = sub {
                    my ($input, $owner, $repo, $rev) = @_;

                    my $key = $owner . "-" . $repo . "-" . $rev;
                    return if exists $seen{$input}->{$key};
                    $seen{$input}->{$key} = 1;

                    my $url = "$apibase/repos/$owner/$repo/statuses/$rev";
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

                    # These are optional so we can just skip them if they aren't provided.
                    return unless defined $limit && defined $limitRemaining && defined $limitReset;

                    my $now = time();
                    my $diff = max(1, $limitReset - $now);
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
                    my ($fhost, $owner, $repo, $rev) = parseFlakeRef($fl);
                    if (!defined $fhost) {
                        print STDERR "Can't parse flake, skipping GitHub status update\n";
                    } elsif ($fhost ne $host) {
                        print STDERR "Flake is on $fhost, not $host, skipping GitHub status update\n";
                    } else {
                        $sendStatus->("src", $owner, $repo, $rev);
                    }
                } else {
                    foreach my $input (@inputs) {
                        my $i = $eval->jobsetevalinputs->find({ name => $input, altnr => 0 });
                        if (! defined $i) {
                            print STDERR "Evaluation $eval doesn't have input $input\n";
                        }
                        next unless defined $i;
                        my ($ihost, $owner, $repo) = parseRepoUri($i->uri);
                        if (!defined $ihost) {
                            print STDERR "Can't parse the URI of input $input, skipping GitHub status update\n";
                        } elsif ($ihost ne $host) {
                            print STDERR "Input $input is on $ihost, not $host, skipping GitHub status update\n";
                        } else {
                            $sendStatus->($input, $owner, $repo, $i->revision);
                        }
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

package Hydra::Plugin::GithubPulls;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use JSON::MaybeXS;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::Nix;
use Hydra::StorePath;
use File::Temp;
use POSIX qw(strftime);

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'githubpulls'} = 'Open GitHub Pull Requests';
}

sub _iterate {
    my ($url, $auth, $pulls, $ua) = @_;
    my $req = HTTP::Request->new('GET', $url);
    $req->header('Accept' => 'application/vnd.github.v3+json');
    $req->header('Authorization' => $auth) if defined $auth;
    my $res = $ua->request($req);
    my $content = $res->decoded_content;
    die "Error pulling from the github pulls API: $content\n"
        unless $res->is_success;
    my $pulls_list = decode_json $content;
    # TODO Stream out the json instead
    foreach my $pull (@$pulls_list) {
        $pulls->{$pull->{number}} = $pull;
    }
    # TODO Make Link header parsing more robust!!!
    my @links = split /,/, ($res->header("Link") // "");
    my $next = "";
    foreach my $link (@links) {
        my ($url, $rel) = split /;/, $link;
        if (trim($rel) eq 'rel="next"') {
            $next = substr trim($url), 1, -1;
            last;
        }
    }
    _iterate($next, $auth, $pulls, $ua) unless $next eq "";
}

# Splits allowlist values from hydra.conf.
sub toArray {
    my ($val) = @_;
    return () unless defined $val;
    return map { split " ", $_ } (ref $val eq "ARRAY" ? @$val : ($val));
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef if $type ne "githubpulls";

    # Value is "OWNER REPO [HOST]"; HOST (e.g. git.example.com) selects a GHE API base.
    my ($owner, $repo, $host, @extra) = split " ", ($value // "");
    if (!defined $repo or @extra) {
        die "githubpulls input `$name' must be 'OWNER REPO [HOST]', got '" . ($value // "") . "'\n";
    }

    my $hasHost = defined $host && $host ne "github.com";
    my $resolvedHost = $hasHost ? $host : "github.com";

    my $cfg = $self->{config}->{githubpulls};
    my $conf = ref $cfg eq "HASH" ? $cfg : {};
    my @allowedRepos = toArray($conf->{allowed_repos});
    my @allowedHosts = toArray($conf->{allowed_hosts});

    # The token is sent to this host, so any host but github.com must be allowlisted.
    # Check it if allowed_hosts is set or the host isn't GitHub.
    my $hostFound = grep { $_ eq $resolvedHost } @allowedHosts;
    if ((scalar @allowedHosts > 0 or $hasHost) and not $hostFound) {
        die "githubpulls input `$name': host '$resolvedHost' is not in githubpulls allowed_hosts in hydra.conf\n";
    }

    my $fullName = "$owner/$repo";
    my $ownerWildcard = "$owner/*";
    if (@allowedRepos and !grep { $_ eq $fullName or $_ eq $ownerWildcard } @allowedRepos) {
        die "githubpulls input `$name': '$owner/$repo' is not in githubpulls allowed_repos in hydra.conf\n";
    }

    my $auth = $self->{config}->{github_authorization}->{$owner};
    my $apibase = $hasHost ? "https://$resolvedHost/api/v3" : "https://api.github.com";
    my %pulls;
    my $ua = LWP::UserAgent->new();
    _iterate("$apibase/repos/$owner/$repo/pulls?per_page=100", $auth, \%pulls, $ua);
    my $tempdir = File::Temp->newdir("github-pulls" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/github-pulls.json";

    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh JSON->new->utf8->canonical->encode(\%pulls);
    close $fh;

    my $storePath = addToStore($filename);
    my $timestamp = time;
    return { storePath => $storePath, revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp) };
}

1;

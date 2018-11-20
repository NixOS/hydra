# This plugin allows to build Gitlab merge requests.
#
# The declarative project spec.json file must contains an input such as
#   "pulls": {
#      "type": "gitlabpulls",
#      "value": "https://gitlab.com 42",
#      "emailresponsible": false
#   }
# where 42 is the project id of a repository.
#
# The values `target_repo_url` and `iid` can then be used to
# build the git input value, e.g.:
# "${target_repo_url} merge-requests/${iid}/head".

package Hydra::Plugin::GitlabPulls;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use JSON;
use Hydra::Helper::CatalystUtils;
use File::Temp;
use POSIX qw(strftime);

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'gitlabpulls'} = 'Open Gitlab Merge Requests';
}

sub _query {
    my ($url, $ua) = @_;
    my $req = HTTP::Request->new('GET', $url);
    my $res = $ua->request($req);
    my $content = $res->decoded_content;
    die "Error pulling from the gitlab pulls API: $content\n"
        unless $res->is_success;
    return (decode_json $content, $res);
}

sub _iterate {
    my ($url, $baseUrl, $pulls, $ua, $target_repo_url) = @_;
    my ($pulls_list, $res) = _query($url, $ua);

    foreach my $pull (@$pulls_list) {
        $pull->{target_repo_url} = $target_repo_url;
        $pulls->{$pull->{iid}} = $pull;
    }
    # TODO Make Link header parsing more robust!!!
    my @links = split ',', $res->header("Link");
    my $next = "";
    foreach my $link (@links) {
        my ($url, $rel) = split ";", $link;
        if (trim($rel) eq 'rel="next"') {
            $next = substr trim($url), 1, -1;
            last;
        }
    }
    _iterate($next, $baseUrl, $pulls, $ua, $target_repo_url) unless $next eq "";
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef if $type ne "gitlabpulls";

    (my $baseUrl, my $projectId) = split ' ', $value;
    my $url = "$baseUrl/api/v4/projects/$projectId/merge_requests?per_page=100&state=opened";

    my $accessToken = $self->{config}->{gitlab_authorization}->{$projectId};

    my %pulls;
    my $ua = LWP::UserAgent->new();
    $ua->default_header('Private-Token' => $accessToken) if defined $accessToken;

    # Get the target project URL, as it is the one we need to build the pull
    # urls from later
    (my $repo, my $res) = _query("$baseUrl/api/v4/projects/$projectId", $ua);
    my $target_repo_url = $repo->{http_url_to_repo};

    _iterate($url, $baseUrl, \%pulls, $ua, $target_repo_url);

    my $tempdir = File::Temp->newdir("gitlab-pulls" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/gitlab-pulls.json";
    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh encode_json \%pulls;
    close $fh;
    system("jq -S . < $filename > $tempdir/gitlab-pulls-sorted.json");
    my $storePath = trim(`nix-store --add "$tempdir/gitlab-pulls-sorted.json"`
        or die "cannot copy path $filename to the Nix store.\n");
    chomp $storePath;
    my $timestamp = time;
    return { storePath => $storePath, revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp) };
}

1;

# Allow building based on Gitea pull requests.
#
# Example input:
#   "pulls": {
#     "type": "giteapulls",
#     "value": "example.com alice repo"
#     "emailresponsible": false
#   }

package Hydra::Plugin::GiteaPulls;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use JSON::MaybeXS;
use Hydra::Helper::CatalystUtils;
use File::Temp;
use POSIX qw(strftime);

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'giteapulls'} = 'Open Gitea Pull Requests';
}

sub _iterate {
    my ($url, $auth, $pulls, $ua) = @_;

    my $req = HTTP::Request->new('GET', $url);
    $req->header('Authorization' => 'token ' . $auth) if defined $auth;

    my $res = $ua->request($req);
    my $content = $res->decoded_content;
    die "Error pulling from the gitea pulls API: $content\n"
	unless $res->is_success;

    my $pulls_list = decode_json $content;

    foreach my $pull (@$pulls_list) {
	$pulls->{$pull->{number}} = $pull;
    }

    # TODO Make Link header parsing more robust!!!
    my @links = split ',', ($res->header("Link") // "");
    my $next = "";
    foreach my $link (@links) {
        my ($url, $rel) = split ";", $link;
        if (trim($rel) eq 'rel="next"') {
            $next = substr trim($url), 1, -1;
            last;
        }
    }
    _iterate($next, $auth, $pulls, $ua) unless $next eq "";
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef if $type ne "giteapulls";

    my ($baseUrl, $owner, $repo, $proto) = split ' ', $value;
    if (not defined $proto) { # the protocol handler is exposed as an option in order to do integration testing
	$proto = "https"
    }
    my $auth = $self->{config}->{gitea_authorization}->{$owner};

    my $ua = LWP::UserAgent->new();
    my %pulls;
    _iterate("$proto://$baseUrl/api/v1/repos/$owner/$repo/pulls?limit=100", $auth, \%pulls, $ua);

    my $tempdir = File::Temp->newdir("gitea-pulls" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/gitea-pulls.json";
    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh encode_json \%pulls;
    close $fh;

    my $storePath = trim(`nix-store --add "$filename"`
        or die "cannot copy path $filename to the Nix store.\n");
    chomp $storePath;
    my $timestamp = time;
    return { storePath => $storePath, revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp) };
}

1;

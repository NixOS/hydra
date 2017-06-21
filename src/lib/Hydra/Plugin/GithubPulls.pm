package Hydra::Plugin::GithubPulls;

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
    my @links = split ',', $res->header("Link");
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
    return undef if $type ne "githubpulls";
    # TODO Allow filtering of some kind here?
    (my $owner, my $repo) = split ' ', $value;
    my $auth = $self->{config}->{github_authorization}->{$owner};
    my %pulls;
    my $ua = LWP::UserAgent->new();
    _iterate("https://api.github.com/repos/$owner/$repo/pulls?per_page=100", $auth, \%pulls, $ua);
    my $tempdir = File::Temp->newdir("github-pulls" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/github-pulls.json";
    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh encode_json \%pulls;
    close $fh;
    system("jq -S . < $filename > $tempdir/github-pulls-sorted.json");
    my $storePath = `nix-store --add "$tempdir/github-pulls-sorted.json"`
        or die "cannot copy path $filename to the Nix store.\n";
    my $timestamp = time;
    return { storePath => $storePath, revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp) };
}

1;

package Hydra::Plugin::BitBucketPulls;

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
    $inputTypes->{'bitbucketpulls'} = 'Open BitBucket Pull Requests';
}

sub _iterate {
    my ($url, $auth, $pulls, $ua) = @_;
    my $req = HTTP::Request->new('GET', $url);
    $req->header('Authorization' => $auth) if defined $auth;
    my $res = $ua->request($req);
    my $content = $res->decoded_content;
    die "Error pulling from the bitbucket pulls API: $content\n"
        unless $res->is_success;
    my $response = decode_json $content;
    my $pulls_list = $response->{values};
    # TODO Stream out the json instead
    foreach my $pull (@$pulls_list) {
        $pulls->{$pull->{id}} = $pull;
    }
    my $next = $response->{next};
    _iterate($next, $auth, $pulls, $ua) unless $next eq "";
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef if $type ne "bitbucketpulls";
    # TODO Allow filtering of some kind here?
    (my $owner, my $repo) = split ' ', $value;
    my $auth = $self->{config}->{bitbucket_authorization}->{$owner};
    my %pulls;
    my $ua = LWP::UserAgent->new();
    _iterate("https://api.bitbucket.com/2.0/repositories/$owner/$repo/pullrequests?state=OPEN", $auth, \%pulls, $ua);
    my $tempdir = File::Temp->newdir("bitbucket-pulls" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/bitbucket-pulls.json";
    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh encode_json \%pulls;
    close $fh;
    system("jq -S . < $filename > $tempdir/bitbucket-pulls-sorted.json");
    my $storePath = trim(`nix-store --add "$tempdir/bitbucket-pulls-sorted.json"`
        or die "cannot copy path $filename to the Nix store.\n");
    chomp $storePath;
    my $timestamp = time;
    return { storePath => $storePath, revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp) };
}

1;

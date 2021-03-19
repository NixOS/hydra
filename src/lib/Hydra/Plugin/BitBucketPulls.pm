package Hydra::Plugin::BitBucketPulls;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use LWP::UserAgent;
use LWP::Authen::OAuth2;
use JSON;
use Hydra::Helper::CatalystUtils;
use File::Temp;
use POSIX qw(strftime);

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'bitbucketpulls'} = 'Open Bitbucket Pull Requests';
}

sub getToken {
    my ($auth, $ua) = @_;
    my $token_url = "https://bitbucket.org/site/oauth2/access_token";
    my $out = `curl -X POST -u $auth->{key}:$auth->{secret} $token_url -d grant_type=client_credentials`;
    my $ojson= decode_json $out;
    my $token = $ojson->{access_token} or die "Error occurred in access-token request.";

    return $token
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
    foreach my $pull (@$pulls_list) {
        $pulls->{$pull->{id}} = $pull;
    }
    my $next = $response->{next};
    _iterate($next, $auth, $pulls, $ua) unless ($next eq undef || $next eq "");
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef if $type ne "bitbucketpulls";
    # TODO Allow filtering of some kind here?
    (my $owner, my $repo) = split ' ', $value;
    my $auth;
    my $url = "https://api.bitbucket.org/2.0/repositories/$owner/$repo/pullrequests?state=OPEN";
    my $bitbucket = $self->{config}->{bitbucket};
    if (! defined $bitbucket) {
        $bitbucket = $self->{config}->{bitbucket_authorization};
    }
    if (defined $bitbucket->{key} and defined $bitbucket->{secret}) {
        # Bitbucket OAuth2 authentication
        my $token = getToken($bitbucket);
        $url = join "", $url, "&access_token=", $token;
    }
    # Bitbucket authentication fallback
    else {
        $auth = $bitbucket->{$owner};
    }
    # Get pull request list
    my %pulls;
    my $ua = LWP::UserAgent->new();
    _iterate($url, $auth, \%pulls, $ua);
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

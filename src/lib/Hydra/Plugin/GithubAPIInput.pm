package Hydra::Plugin::GithubAPIInput;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'githubAPI'} = 'GitHub API Query';
}

sub fetchInput {
    my ($self, $type, $name, $value) = @_;

    return undef if $type ne "githubAPI";

    # Use the GithubStatus plugin's authorization.
    # TODO: move this into a more cleanly shared field.
    my $config = $self->{config}->{githubstatus};

    my $url = "https://api.github.com" . $value;
    my $ua = LWP::UserAgent->new();
    my $req = HTTP::Request->new('GET', $url);
    $req->header('Accept' => 'application/vnd.github.v3+json');
    $req->header('Authorization' => $config->{authorization});
    my $res = $ua->request($req);
    print STDERR ("Performing GitHub API request: " . $url . "\n");

    return { value => $res->decoded_content };
}

1;


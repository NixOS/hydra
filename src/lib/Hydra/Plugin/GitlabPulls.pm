# This plugin allows to build Gitlab merge requests
# with a declarative project.
# 
# Hydra configuration
# - `gitlab_authorization.access_token`
# - `gitlab_authorization.projects.<projectId>.access_token`
# Project configuration
# - base_url
# - project_id
# - clone_type
# - access_token

package Hydra::Plugin::GitlabPulls;

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
    $inputTypes->{'gitlabpulls'} = 'Open Gitlab Merge Requests';
}

sub _query {
    my ($url, $ua) = @_;
    my $req = HTTP::Request->new('GET', $url);
    my $res = $ua->request($req);
    my $content = $res->decoded_content;
    die "Error pulling from the gitlab pulls\nUrl: $url\nContent: $content\n"
        unless $res->is_success;
    return (decode_json $content, $res);
}

sub _iterate {
    my ($url, $config, $repo, $mrs, $ua) = @_;

    my ($mrs_list, $res) = _query($url, $ua);

    foreach my $mr (@$mrs_list) {
        my $jobset = gitlabMrToJobset($config, $repo, $mr);
        my $mrIID = $mr->{iid};
        $mrs->{"MR${mrIID}"} = $jobset;
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
    _iterate($next, $config, $repo, $mrs, $ua) unless $next eq "";
}

sub gitlabMrToJobset {
    my ($config, $repo, $mr) = @_;

    # $repo content https://docs.gitlab.com/ee/api/projects.html
    # $mr content https://docs.gitlab.com/ee/api/merge_requests.html
    my $mrTitle = $mr->{title};
    my $mrIID = $mr->{iid};

    my $clone_type = $config->{clone_type} || "http";
    my $git_target = undef;
    
    if ($clone_type eq "http") {
        $git_target = $repo->{http_url_to_repo};
    } elsif ($clone_type eq "ssh") {
        $git_target = $repo->{ssh_url_to_repo};
    } else {
        die "Unknown clone_type: `$clone_type`";
    }

    my $targetRepoId  = $repo->{id};

    # TODO allwo jobset configuration
    # BTW nice place to overlay here!!
    my $jobset =
        { enabled => 1
        , hidden => 0
        , description => "MR${mrIID}: ${mrTitle}"
        , nixexprinput => "gitlab"
        , nixexprpath => "default.nix"
        , checkinterval => 50
        , schedulingshares => 50
        , enabled => 1
        , enableemail => 0
        , emailoverride => ""
        , keepnr => 2
        , inputs =>
          { gitlab => { type => "git", value => "${git_target} merge-requests/${mrIID}/head", emailresponsible => 0 }
            # TODO add here gitlabstatus stuff
          }
        };

    return $jobset
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef if $type ne "gitlabpulls";

    my $config = decode_json($value);
    # The url or your Gitlab instance 
    my $baseUrl = $config->{'base_url'} || "https://gitlab.com";

    # $subject is the first part of the Gitlab API in which the 
    # subject is specified, `projects` is not the only subject that
    # the api allow to use
    # TODO support more subjects
    my $subject = "";
    if (defined $config->{'project_id'}) {
        my $projectId = $config->{'project_id'};
        $subject = "projects/$projectId/";
    } else {
        die "missing 'project_id' field";
    }
    $config->{'subject'} = $subject;

    my %pulls;
    my $ua = LWP::UserAgent->new();

    # Authorization for the Gitlab http API
    # retrieve the access token from:
    # - hydra configuration -> gitlab_authorization
    # - project configuration
    my $accessToken = undef;
    my $gitlabConfig = $self->{config}->{gitlab_authorization};

    my $gitlabAccessToken = $gitlabConfig->{'access_token'};
    if (defined $gitlabAccessToken){
        $accessToken = $gitlabAccessToken;
    }

    my $projectId = $config->{'project_id'};
    my $gitlabProjectAccessToken = $gitlabConfig->{'projects'}->{$projectId}->{'access_token'};
    if (defined $gitlabProjectAccessToken){
        $accessToken = $gitlabProjectAccessToken;
    }

    my $hydraProjectAccessToken = $config->{'access_token'};
    if (defined $hydraProjectAccessToken){
        $accessToken = $hydraProjectAccessToken;
    }
    
    if (defined $accessToken) {
        $ua->default_header('Private-Token' => $accessToken);
    } else {
        die "missing Gitlab access_token";
    }

    # Get the target project URL, as it is the one we need to build the pull
    # urls from later
    (my $repo, my $res) = _query("$baseUrl/api/v4/${subject}", $ua);

    my $url = "$baseUrl/api/v4/${subject}merge_requests?per_page=100&state=opened";
    _iterate($url, $config, $repo, \%pulls, $ua);

    my $tempdir = File::Temp->newdir("gitlab-pulls" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/gitlab-pulls.json";
    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh encode_json \%pulls;
    close $fh;
    my $storePath = trim(`nix-store --add "$tempdir"`
        or die "cannot copy path $tempdir to the Nix store.\n");
    chomp $storePath;

    print STDERR "gitlab-pulls.jobs path: $storePath\n";
    my $timestamp = time;
    return { 
        storePath => $storePath,
        revision => strftime("%Y%m%d%H%M%S", gmtime($timestamp))
    };
}

1;

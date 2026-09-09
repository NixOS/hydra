use strict;
use warnings;
use Setup;
use Test2::V0;
use HTTP::Response;

# The plugin sleeps to respect GitHub's rate limit; record that instead.
my @slept;
BEGIN { *CORE::GLOBAL::sleep = sub { push @slept, $_[0]; return 0 } }

require Hydra::Plugin::GithubStatus;

my $rev = "0123456789abcdef0123456789abcdef01234567";

# Record the statuses posted instead of sending them.
my @requests;
our $rateLimitHeaders = 1;
{
    no warnings qw(redefine once);
    *LWP::UserAgent::request = sub {
        my ($ua, $req) = @_;
        push @requests, { url => $req->uri->as_string, auth => scalar $req->header('Authorization') };
        my $res = HTTP::Response->new(201);
        if ($rateLimitHeaders) {
            $res->header('X-RateLimit-Limit' => 5000);
            $res->header('X-RateLimit-Remaining' => 4999);
            $res->header('X-RateLimit-Reset' => time() + 3600);
        }
        return $res;
    };
}

# Just enough of the build and evaluation rows for the plugin.
package FakeBuild {
    sub new { my ($class, %args) = @_; return bless {%args}, $class }
    sub jobset { return FakeJobset->new }
    sub get_column { return "build" }
    sub finished { return 1 }
    sub buildstatus { return 0 }
    sub id { return 42 }
    # A fresh result set each time, which stops returning rows once read to the end.
    sub jobsetevals { my ($self) = @_; return FakeResultSet->new(@{$self->{evals}}) }
}
package FakeJobset {
    sub new { return bless {}, shift }
    sub get_column { my ($self, $col) = @_; return { project => "proj", name => "jobset" }->{$col} }
}
package FakeResultSet {
    sub new { my ($class, @rows) = @_; return bless [@rows], $class }
    sub next { my ($self) = @_; return shift @$self }
}
package FakeEval {
    sub new { my ($class, %args) = @_; return bless {%args}, $class }
    sub id { return 1 }
    sub flake { return $_[0]->{flake} }
    sub jobsetevalinputs { return FakeInputs->new(%{$_[0]->{inputs} // {}}) }
}
package FakeInputs {
    sub new { my ($class, %inputs) = @_; return bless {%inputs}, $class }
    sub find {
        my ($self, $query) = @_;
        my $input = $self->{$query->{name}};
        return defined $input ? FakeInput->new(%$input) : undef;
    }
}
package FakeInput {
    sub new { my ($class, %args) = @_; return bless {%args}, $class }
    sub uri { return $_[0]->{uri} }
    sub revision { return $_[0]->{revision} }
}
package main;

# Finishes a build of an evaluation with the given flake or inputs, and
# returns the status URLs posted.
sub statuses {
    my ($githubstatus, %eval) = @_;
    @requests = ();
    my $plugin = Hydra::Plugin::GithubStatus->new(config => {
        github_authorization => { OWNER1 => "token owner1-secret" },
        githubstatus => $githubstatus,
    });
    $plugin->buildFinished(FakeBuild->new(evals => [ FakeEval->new(%eval) ]), []);
    return [ map { $_->{url} } @requests ];
}

my $github = "https://api.github.com/repos/OWNER1/repo1/statuses/$rev";
my $ghe = "https://git.example.com/api/v3/repos/OWNER1/repo1/statuses/$rev";
my %onGhe = (jobs => ".*", host => "git.example.com");

subtest "github: flakes on github.com" => sub {
    is(statuses({ jobs => ".*" }, flake => "github:OWNER1/repo1/$rev?narHash=sha256-x"), [$github]);
    is($requests[0]->{auth}, "token owner1-secret");
    is(statuses({ jobs => ".*" }, flake => "github:OWNER1/repo1/$rev"), [$github], "without a query");
};

subtest "github: flakes with ?host= go to the configured host" => sub {
    is(statuses({%onGhe}, flake => "github:OWNER1/repo1/$rev?dir=nix%2Fhydra&host=git.example.com&narHash=sha256-x"), [$ghe]);
};

subtest "git+https and git+ssh flakes" => sub {
    is(statuses({ jobs => ".*" }, flake => "git+https://github.com/OWNER1/repo1?ref=main&rev=$rev"), [$github], "github.com");
    is(statuses({%onGhe}, flake => "git+https://git.example.com/OWNER1/repo1.git?rev=$rev"), [$ghe], "https");
    is(statuses({%onGhe}, flake => "git+ssh://git\@git.example.com/OWNER1/repo1.git?ref=main&rev=$rev"), [$ghe], "ssh");
    is(statuses({%onGhe}, flake => "git+ssh://git\@git.example.com:2222/OWNER1/repo1?rev=$rev"), [$ghe], "the SSH port says nothing about the API");
    is(statuses({%onGhe}, flake => "git+https://git.example.com/OWNER1/repo1?ref=refs/heads/me\@feature&rev=$rev"), [$ghe], "an \@ in the query");
    is(statuses({%onGhe}, flake => "git+https://git.example.com/OWNER1/repo1?dir=a/b&narHash=sha256-x&rev=$rev&submodules=1"), [$ghe], "rev among other parameters");
};

subtest "flakes on another host are skipped" => sub {
    is(statuses({ jobs => ".*" }, flake => "github:OWNER1/repo1/$rev?host=git.example.com"), [], "github: flake on GHE, github.com configured");
    is(statuses({%onGhe}, flake => "github:OWNER1/repo1/$rev"), [], "github: flake on github.com, GHE configured");
    is(statuses({ jobs => ".*" }, flake => "git+https://git.example.com/OWNER1/repo1?rev=$rev"), [], "git+https flake on GHE, github.com configured");
};

subtest "host matching is exact, including case" => sub {
    is(statuses({ jobs => ".*", host => "Git.Example.com" }, flake => "git+https://git.example.com/OWNER1/repo1?rev=$rev"), [], "git+https flake");
    is(statuses({%onGhe}, flake => "github:OWNER1/repo1/$rev?host=Git.Example.com"), [], "github: flake");
    is(statuses({%onGhe, inputs => "src"}, inputs => { src => { uri => "git\@Git.Example.com:OWNER1/repo1.git", revision => $rev } }), [], "non-flake input");
    is(statuses({ jobs => ".*" }, flake => "git+https://GitHub.com/OWNER1/repo1?rev=$rev"), [], "github.com");
};

subtest "unparseable flakes are skipped" => sub {
    is(statuses({ jobs => ".*" }, flake => "path:/somewhere"), []);
    is(statuses({ jobs => ".*" }, flake => "github:OWNER1/repo1"), [], "no revision");
    is(statuses({ jobs => ".*" }, flake => "git+https://github.com/OWNER1/repo1?ref=main"), [], "no revision");
    is(statuses({ jobs => ".*" }, flake => "git+https://github.com/OWNER1/repo1?prev=$rev"), [], "not the rev parameter");
    is(statuses({ jobs => ".*" }, flake => "git+https://github.com/a/OWNER1/repo1?rev=$rev"), [], "not OWNER/REPO");
};

subtest "non-flake inputs only go to the configured host" => sub {
    my %src = (uri => "https://github.com/OWNER1/repo1.git", revision => $rev);
    is(statuses({ jobs => ".*", inputs => "src" }, inputs => { src => {%src} }), [$github], "github.com");
    is(statuses({ %onGhe, inputs => "src" }, inputs => { src => {%src} }), [], "github.com input, GHE configured");
    is(statuses({ %onGhe, inputs => "src" }, inputs => { src => { %src, uri => "git\@git.example.com:OWNER1/repo1.git" } }), [$ghe], "scp-style GHE input");
    is(statuses({ %onGhe, inputs => "src" }, inputs => { src => { %src, uri => "ssh://git\@git.example.com:2222/OWNER1/repo1" } }), [$ghe], "ssh:// GHE input");
    is(statuses({ jobs => ".*", inputs => "src" }, inputs => { src => { %src, uri => "/srv/git/OWNER1/repo1" } }), [], "a local path");
};

subtest "each <githubstatus> block sees the evaluations" => sub {
    is(statuses([ { jobs => ".*" }, {%onGhe} ], flake => "git+https://git.example.com/OWNER1/repo1?rev=$rev"), [$ghe]);
};

subtest "responses without rate-limit headers" => sub {
    local $rateLimitHeaders = 0;
    @slept = ();
    ok(no_warnings { statuses({%onGhe}, flake => "github:OWNER1/repo1/$rev?host=git.example.com") }, "no warnings");
    is(\@slept, [], "no sleeping");
};

done_testing;

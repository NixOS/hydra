use strict;
use warnings;
use Setup;
use Test2::V0;

require Hydra::Plugin::GithubPulls;

my @requests;
{
    no warnings qw(redefine once);
    *Hydra::Plugin::GithubPulls::_iterate = sub {
        my ($url, $auth, $pulls, $ua) = @_;
        push @requests, { url => $url, auth => $auth };
        $pulls->{1} = { number => 1 };
    };
    *Hydra::Plugin::GithubPulls::addToStore = sub { return "/nix/store/00000000000000000000000000000000-github-pulls.json" };
}

sub plugin {
    my (%githubpulls) = @_;
    return Hydra::Plugin::GithubPulls->new(config => {
        github_authorization => { OWNER1 => "token repo-secret" },
        (%githubpulls ? (githubpulls => { %githubpulls }) : ()),
    });
}

sub fetch {
    my ($plugin, $value) = @_;
    @requests = ();
    return $plugin->fetchInput("githubpulls", "pulls", $value, undef, undef);
}

subtest "other input types are left to other plugins" => sub {
    is(plugin()->fetchInput("git", "src", "https://example.com/repo", undef, undef), undef);
};

subtest "github.com needs no allowlist while allowed_hosts is unset" => sub {
    ok(fetch(plugin(), "OWNER1 repo1")->{storePath}, "fetched");
    is($requests[0]->{url}, "https://api.github.com/repos/OWNER1/repo1/pulls?per_page=100");
    is($requests[0]->{auth}, "token repo-secret");
    ok(fetch(plugin(), "OWNER1 repo1 github.com"), "github.com named as the host");
};

subtest "another host must be allowlisted, since the token goes there" => sub {
    like(dies { fetch(plugin(), "OWNER1 repo1 git.example.com") }, qr/host 'git\.example\.com' is not in githubpulls allowed_hosts/);
    is(\@requests, [], "nothing was sent");

    ok(fetch(plugin(allowed_hosts => "git.example.com"), "OWNER1 repo1 git.example.com"), "allowlisted host");
    is($requests[0]->{url}, "https://git.example.com/api/v3/repos/OWNER1/repo1/pulls?per_page=100");
};

subtest "once allowed_hosts is set, github.com must be in it too" => sub {
    my $gheOnly = plugin(allowed_hosts => "git.example.com");
    like(dies { fetch($gheOnly, "OWNER1 repo1") }, qr/host 'github\.com' is not in githubpulls allowed_hosts/);
    is(\@requests, [], "nothing was sent");
    like(dies { fetch($gheOnly, "OWNER1 repo1 github.com") }, qr/host 'github\.com' is not in githubpulls allowed_hosts/, "github.com named as the host");

    my $both = plugin(allowed_hosts => "github.com git.example.com");
    ok(fetch($both, "OWNER1 repo1"), "github.com listed");
    is($requests[0]->{url}, "https://api.github.com/repos/OWNER1/repo1/pulls?per_page=100");
    ok(fetch($both, "OWNER1 repo1 git.example.com"), "other host listed");
    is($requests[0]->{url}, "https://git.example.com/api/v3/repos/OWNER1/repo1/pulls?per_page=100");

    like(dies { fetch(plugin(allowed_hosts => "github.com"), "OWNER1 repo1 git.example.com") }, qr/host 'git\.example\.com' is not in githubpulls allowed_hosts/, "only github.com listed");
};

subtest "repos outside allowed_repos are refused" => sub {
    my $p = plugin(allowed_repos => "OWNER1/repo1 OTHER/*");
    ok(fetch($p, "OWNER1 repo1"), "listed repo");
    ok(fetch($p, "OTHER anything"), "owner wildcard");
    like(dies { fetch($p, "OWNER1 repo2") }, qr/'OWNER1\/repo2' is not in githubpulls allowed_repos/);
};

subtest "matching is exact, including case" => sub {
    like(dies { fetch(plugin(allowed_hosts => "git.example.com"), "OWNER1 repo1 Git.Example.com") }, qr/host 'Git\.Example\.com' is not in githubpulls allowed_hosts/);
    like(dies { fetch(plugin(allowed_hosts => "Git.Example.com"), "OWNER1 repo1 git.example.com") }, qr/host 'git\.example\.com' is not in githubpulls allowed_hosts/);
    like(dies { fetch(plugin(), "OWNER1 repo1 GitHub.com") }, qr/host 'GitHub\.com' is not in githubpulls allowed_hosts/, "only github.com itself needs no allowlist");
    my $p = plugin(allowed_repos => "owner1/* OWNER2/Repo");
    like(dies { fetch($p, "OWNER1 repo1") }, qr/'OWNER1\/repo1' is not in githubpulls allowed_repos/, "owner wildcard");
    like(dies { fetch($p, "OWNER2 repo") }, qr/'OWNER2\/repo' is not in githubpulls allowed_repos/, "listed repo");
    is(\@requests, [], "nothing was sent");
};

subtest "repeated config lines work like one space-separated line" => sub {
    my $p = plugin(allowed_repos => ["OWNER1/repo1", "OWNER2/a OWNER2/b"]);
    ok(fetch($p, "OWNER2 b"), "from a repeated line");
    like(dies { fetch($p, "OWNER2 c") }, qr/not in githubpulls allowed_repos/);
};

subtest "the value must be OWNER REPO [HOST]" => sub {
    like(dies { fetch(plugin(), "OWNER1") }, qr/must be 'OWNER REPO \[HOST\]'/);
    like(dies { fetch(plugin(allowed_hosts => "git.example.com"), "OWNER1 repo1 git.example.com extra") }, qr/must be 'OWNER REPO \[HOST\]'/);
    ok(fetch(plugin(allowed_hosts => "git.example.com"), "  OWNER1 repo1 git.example.com  "), "surrounding whitespace is fine");
    is($requests[0]->{url}, "https://git.example.com/api/v3/repos/OWNER1/repo1/pulls?per_page=100");
};

done_testing;

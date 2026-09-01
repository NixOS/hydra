use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Slurper qw(write_text);
use Hydra::Config;
use Test2::V0;

my $dir = tempdir(CLEANUP => 1);

# A secret in a file anyone can read is already leaked, and nothing about
# running Hydra says so. The NixOS module makes this easy to do by accident,
# since everything it writes lands in the world-readable Nix store.

subtest "the settings that hold a secret are recognised" => sub {
    is(
        [ Hydra::Config::secretsIn({ github_authorization => { NixOS => "Bearer x" } }) ],
        [ "github_authorization" ],
        "a block that is entirely secret"
    );
    is(
        [ Hydra::Config::secretsIn({ githubstatus => { jobs => "j", authorization => "x" } }) ],
        [ "githubstatus.authorization" ],
        "a secret setting inside a block that is not"
    );
    is(
        [ Hydra::Config::secretsIn({ githubstatus => { jobs => "j" } }) ],
        [],
        "the same block without the secret"
    );
    is(
        [ Hydra::Config::secretsIn({ max_servers => 25 }) ],
        [],
        "an ordinary setting"
    );
};

subtest "a repeated block is searched too" => sub {
    # Repeated blocks are a list here and a single one is not, so the search
    # cannot count list nesting as a step in the path.
    is(
        [ Hydra::Config::secretsIn({ circleci => [ { jobs => "j" }, { token => "t" } ] }) ],
        [ "circleci.token" ],
        "found in the second of two blocks"
    );
};

subtest "world-readable means readable by anyone" => sub {
    write_text("$dir/open.json", "{}");
    write_text("$dir/shut.json", "{}");
    chmod 0644, "$dir/open.json";
    chmod 0640, "$dir/shut.json";

    is(Hydra::Config::isWorldReadable("$dir/open.json"), T(), "0644");
    is(Hydra::Config::isWorldReadable("$dir/shut.json"), F(),
        "0640 -- readable by Hydra's group, which is the point of a secrets file");
};

subtest "loading reports secrets in files anyone can read" => sub {
    write_text("$dir/secrets.json", '{"github_authorization": {"NixOS": "Bearer x"}}');
    write_text("$dir/main.json", '{"includes": ["secrets.json"], "settings": {"max_servers": "25"}}');
    chmod 0644, "$dir/main.json";

    subtest "a secrets file only Hydra can read is fine" => sub {
        chmod 0600, "$dir/secrets.json";
        my @insecure;
        Hydra::Config::loadConfig("$dir/main.json", { insecure => \@insecure });
        is(\@insecure, [], "nothing to report");
    };

    subtest "the same secret in a file anyone can read is not" => sub {
        chmod 0644, "$dir/secrets.json";
        my @insecure;
        Hydra::Config::loadConfig("$dir/main.json", { insecure => \@insecure });
        is(\@insecure, [ {
            file => "$dir/secrets.json",
            settings => [ "github_authorization" ],
        } ], "blamed on the file the secret is in, not the one that included it");
    };
};

subtest "nothing is reported unless it is asked for" => sub {
    # The check is a lint. Loading a configuration must not start failing
    # because of it.
    write_text("$dir/inline.json", '{"github_authorization": {"NixOS": "Bearer x"}}');
    chmod 0644, "$dir/inline.json";
    ok(lives { Hydra::Config::loadConfig("$dir/inline.json") }, "loads without complaint");
};

done_testing;

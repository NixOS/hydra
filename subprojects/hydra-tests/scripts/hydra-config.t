use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Slurper qw(write_text);
use IPC::Run3;
use JSON::MaybeXS;
use Test2::V0;

# `Hydra::Config` is tested directly elsewhere. What is tested here is the
# command's contract: what it prints, and what it exits with. The NixOS module
# runs it while building and depends on a non-zero exit to fail the
# deployment, so an exit status that stopped being non-zero would quietly turn
# that check off.

my $dir = tempdir(CLEANUP => 1);

sub hydra_config {
    my (@args) = @_;
    my ($stdout, $stderr) = ("", "");
    run3([ "hydra-config", @args ], \undef, \$stdout, \$stderr);
    return ($? >> 8, $stdout, $stderr);
}

write_text("$dir/ok.json", '{"max_servers": "25"}');

subtest "a configuration it can read" => sub {
    my ($status, $stdout, $stderr) = hydra_config("$dir/ok.json");
    is($status, 0, "exits zero");
    is(decode_json($stdout), { max_servers => "25" }, "prints the configuration as JSON");
    is($stderr, "", "and says nothing else");
};

subtest "a configuration it cannot read" => sub {
    write_text("$dir/broken.json", "{ not json");
    my ($status, $stdout, $stderr) = hydra_config("$dir/broken.json");
    is($status, 1, "exits non-zero");
    like($stderr, qr/Error parsing/, "says what was wrong with it");
    unlike($stderr, qr/line \d+\./, "without the perl file and line that raised it");
};

subtest "a file it will not parse at all" => sub {
    write_text("$dir/hydra.ini", "max_servers = 25\n");
    my ($status, undef, $stderr) = hydra_config("$dir/hydra.ini");
    is($status, 1, "exits non-zero");
    like($stderr, qr/no parser for this file/, "says so");
};

subtest "several files are folded together" => sub {
    write_text("$dir/more.json", '{"compress_build_logs": "1"}');
    my ($status, $stdout) = hydra_config("$dir/ok.json", "$dir/more.json");
    is($status, 0, "exits zero");
    is(decode_json($stdout), { max_servers => "25", compress_build_logs => "1" },
        "with the settings of both");

    my ($conflict, undef, $stderr) = hydra_config("$dir/ok.json", "$dir/ok.json");
    is($conflict, 1, "a setting in two of them exits non-zero");
    like($stderr, qr/is set in both/, "rather than one of them quietly winning");
};

subtest "a secret where anyone can read it" => sub {
    write_text("$dir/leak.json", '{"github_authorization": {"NixOS": "Bearer x"}}');
    chmod 0644, "$dir/leak.json";

    my ($status, $stdout, $stderr) = hydra_config("$dir/leak.json");
    is($status, 1, "exits non-zero, so a build that runs this fails");
    like($stderr, qr/world-readable and sets `github_authorization'/, "names the file and the setting");
    ok(length($stdout), "the configuration is still printed, so the failure is not mistaken for a parse error");

    chmod 0600, "$dir/leak.json";
    my ($shut) = hydra_config("$dir/leak.json");
    is($shut, 0, "and is fine once nobody else can read it");
};

subtest "--no-includes" => sub {
    # What the NixOS module runs while building: the file is in the Nix store,
    # and the files it includes are runtime paths that are not in the sandbox.
    write_text("$dir/runtime.json",
        '{"includes": ["/run/keys/hydra/nope.json"], "settings": {"max_servers": "25"}}');

    my ($without, undef, $stderr) = hydra_config("$dir/runtime.json");
    is($without, 1, "without it, an include that is not there is an error");
    like($stderr, qr/does not exist/, "saying so");

    my ($with, $stdout) = hydra_config("--no-includes", "$dir/runtime.json");
    is($with, 0, "with it, the unreadable include is not required");
    is(decode_json($stdout), { max_servers => "25" }, "and only this file's settings are printed");

    write_text("$dir/store.json",
        '{"includes": ["/run/keys/hydra/nope.json"],
          "settings": {"github_authorization": {"NixOS": "Bearer x"}}}');
    chmod 0644, "$dir/store.json";
    my ($leak, undef, $leakErr) = hydra_config("--no-includes", "$dir/store.json");
    is($leak, 1, "it still refuses a secret anyone can read");
    like($leakErr, qr/world-readable/, "which is the check the module is there to make");
};

done_testing;

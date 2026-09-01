use strict;
use warnings;
use File::Temp qw(tempdir);
use File::Slurper qw(write_text);
use Hydra::Config;
use Test2::V0;

my $dir = tempdir(CLEANUP => 1);

# The same configuration, said both ways. Which parser runs is decided by the
# extension, and the two are expected to produce the same structure -- that is
# what lets everything downstream stay ignorant of how it was written.
write_text("$dir/hydra.conf", <<'CONF');
max_servers = 25

<email_notifications>
  build = 1
</email_notifications>

<runcommand>
  job = a:*:*
</runcommand>

<runcommand>
  job = b:*:*
</runcommand>
CONF

write_text("$dir/hydra.json", <<'JSON');
{
  "max_servers": "25",
  "email_notifications": { "build": "1" },
  "runcommand": [ { "job": "a:*:*" }, { "job": "b:*:*" } ]
}
JSON

my $expected = {
    max_servers => "25",
    email_notifications => { build => "1" },
    runcommand => [ { job => "a:*:*" }, { job => "b:*:*" } ],
};

is(Hydra::Config::loadConfig("$dir/hydra.conf"), $expected, "The Apache-style syntax parses");
is(Hydra::Config::loadConfig("$dir/hydra.json"), $expected, "JSON parses to the same thing");

subtest "a repeated block and a JSON array are both an arrayref" => sub {
    my $conf = Hydra::Config::loadConfig("$dir/hydra.conf");
    my $json = Hydra::Config::loadConfig("$dir/hydra.json");
    is(ref $conf->{runcommand}, "ARRAY", "repeated blocks");
    is(ref $json->{runcommand}, "ARRAY", "JSON array");
};

subtest "a single block is a hashref in both" => sub {
    my $conf = Hydra::Config::loadConfig("$dir/hydra.conf");
    my $json = Hydra::Config::loadConfig("$dir/hydra.json");
    is(ref $conf->{email_notifications}, "HASH", "one block");
    is(ref $json->{email_notifications}, "HASH", "one JSON object");
};

subtest "only the documented formats are accepted" => sub {
    # Config::Any would happily read these; Hydra does not offer them.
    for my $ext (qw(ini yml xml pl txt)) {
        write_text("$dir/hydra.$ext", "max_servers = 25\n");
        like(
            dies { Hydra::Config::loadConfig("$dir/hydra.$ext") },
            qr/no parser for this file/,
            "`.$ext' is refused rather than half-supported"
        );
    }
};

subtest "JSON's own types survive the trip" => sub {
    # Config::General only ever yields strings, so a value written as a JSON
    # number or boolean has to end up meaning the same thing.
    write_text("$dir/types.json", '{"email_notifications": {"build": 1, "eval": true}}');
    my $config = Hydra::Config::loadConfig("$dir/types.json");
    is(buildEmailNotificationEnabled($config), T(), "a number reads as enabled");
    is(evalEmailNotificationEnabled($config), T(), "a boolean reads as enabled");
};

subtest "a bare settings document is taken as it always was" => sub {
    # Nothing is wrapped unless it asks to be, so every configuration written
    # before the envelope existed still means what it did.
    is(Hydra::Config::loadConfig("$dir/hydra.conf")->{max_servers}, "25", "no envelope, no change");
};

subtest "a JSON envelope's includes are folded in" => sub {
    # This is how secrets stay out of the Nix store: the generated file names a
    # path, and the file there is deployed by other means.
    write_text("$dir/secrets.json", '{"githubstatus": {"authorization": "Bearer s3cr3t"}}');
    write_text("$dir/main.json",
        '{"includes": ["secrets.json"],
          "settings": {"githubstatus": {"jobs": "nixos:*:*"}}}');

    is(Hydra::Config::loadConfig("$dir/main.json"), {
        githubstatus => { jobs => "nixos:*:*", authorization => "Bearer s3cr3t" },
    }, "the settings, with the included file folded in");
};

subtest "an included file may be in either format" => sub {
    write_text("$dir/secrets.conf", <<'CONF');
<githubstatus>
  authorization = Bearer from-a-conf
</githubstatus>
CONF
    write_text("$dir/mixed.json", '{"includes": ["secrets.conf"], "settings": {}}');
    is(Hydra::Config::loadConfig("$dir/mixed.json"), {
        githubstatus => { authorization => "Bearer from-a-conf" },
    }, "a `.conf' holding the secrets, included from JSON");
};

subtest "the Apache-style syntax has no envelope" => sub {
    # It has `Include` already, and reading these names there would change what
    # existing files mean.
    write_text("$dir/looks-wrapped.conf", <<'CONF');
includes = secrets.json

<settings>
  max_servers = 25
</settings>
CONF
    is(Hydra::Config::loadConfig("$dir/looks-wrapped.conf"), {
        includes => "secrets.json",
        settings => { max_servers => "25" },
    }, "they are ordinary settings called `includes' and `settings'");
};

subtest "includes can be left unread" => sub {
    # For checking a configuration somewhere its includes are not there to be
    # read: a build sandbox, checking what the NixOS module generated.
    write_text("$dir/runtime.json",
        '{"includes": ["/run/keys/hydra/nope.json"], "settings": {"max_servers": "25"}}');

    like(
        dies { Hydra::Config::loadConfig("$dir/runtime.json") },
        qr/does not exist/,
        "normally an include that is not there is an error"
    );
    is(
        Hydra::Config::loadConfig("$dir/runtime.json", { noIncludes => 1 }),
        { max_servers => "25" },
        "but `noIncludes' takes the file's own settings and stops"
    );
};

subtest "an envelope holds nothing but includes and settings" => sub {
    write_text("$dir/stray.json", '{"settings": {}, "max_servers": "25"}');
    like(
        dies { Hydra::Config::loadConfig("$dir/stray.json") },
        qr/also has `max_servers'/,
        "a setting left outside the envelope is a mistake, not ignored"
    );
};

subtest "merging" => sub {
    write_text("$dir/more.json",
        '{"runcommand": [{"job": "b:*:*"}], "githubstatus": {"authorization": "x"}}');
    write_text("$dir/merge.json",
        '{"includes": ["more.json"],
          "settings": {"runcommand": [{"job": "a:*:*"}],
                       "githubstatus": {"jobs": "j"}}}');
    my $config = Hydra::Config::loadConfig("$dir/merge.json");
    is($config->{runcommand}, [ { job => "a:*:*" }, { job => "b:*:*" } ], "lists append");
    is($config->{githubstatus}, { jobs => "j", authorization => "x" }, "blocks combine");
};

subtest "a setting given in both files is an error" => sub {
    write_text("$dir/conflict.json",
        '{"includes": ["secrets.json"],
          "settings": {"githubstatus": {"authorization": "Bearer mine"}}}');
    like(
        dies { Hydra::Config::loadConfig("$dir/conflict.json") },
        qr/`githubstatus\.authorization' is set in both/,
        "names the setting and both files rather than picking a winner"
    );
};

subtest "includes that reach each other are refused" => sub {
    write_text("$dir/loop.json", '{"includes": ["loop2.json"], "settings": {}}');
    write_text("$dir/loop2.json", '{"includes": ["loop.json"], "settings": {}}');
    like(
        dies { Hydra::Config::loadConfig("$dir/loop.json") },
        qr/is a cycle/,
        "rather than recursing until perl runs out of stack"
    );
};

subtest "an include that names nothing is an error" => sub {
    write_text("$dir/missing.json", '{"includes": ["nope.json"], "settings": {}}');
    like(
        dies { Hydra::Config::loadConfig("$dir/missing.json") },
        qr/does not exist/,
        "a secrets file that failed to deploy is not silently no secrets"
    );
};

done_testing;

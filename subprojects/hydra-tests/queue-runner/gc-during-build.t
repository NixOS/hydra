use strict;
use warnings;
use Setup;
use Test2::V0;
use JSON::PP;
use LWP::UserAgent;
use HTTP::Request;
use File::Slurper qw(write_text);
use NixDaemon qw(start_nix_daemon);
use QueueRunnerContext;

# hydra-builder must keep a build's imported inputs alive across a GC of the
# builder store (it holds them via AddTempRoot on a per-build daemon
# connection). The build handshakes with the test through two sentinel files
# (sandbox is off), so the GC point is deterministic.

my $ctx = test_context(
    use_external_destination_store => 0,
);

my $jobsdir = $ctx->jobsdir;
my $sync    = $ctx->tmpdir . "/gc-sync";
mkdir $sync or die "mkdir $sync: $!";
my $started = "$sync/started";
my $proceed = "$sync/proceed";

# `input` is referenced only inside `args`, not as a derivation attribute, so
# its path stays out of the build's environ: nix's GC scans /proc/*/environ
# for runtime roots, which would otherwise keep it alive regardless of
# hydra-builder's pin and make this test vacuous.
write_text("$jobsdir/gc-during-build.nix", <<NIX);
with import ./config.nix;
rec {
  input = mkDerivation {
    name = "gc-during-build-input";
    builder = bash;
    args = [ "-c" "echo pinned-input > \$out" ];
  };
  slow = mkDerivation {
    name = "gc-during-build-slow";
    builder = bash;
    args = [ "-c" ''
      : >"$started"
      while [ ! -e "$proceed" ]; do sleep 0.05; done
      cat "\${input}" >"\$out"
    '' ];
  };
}
NIX

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "gc-during-build.nix",
    build      => 0,
);

my $slow  = $builds->{"slow"}  or die "slow build missing";
my $input = $builds->{"input"} or die "input build missing";

my ($res, $out, $err) = $ctx->capture_cmd(
    15, "nix-store", "-q", "--outputs", $input->drvpath);
is($res, 0, "querying input output path succeeds") or diag($err);
chomp(my $input_out = $out);
like($input_out, qr{/nix/store/}, "got a store path for input");

my $builder_uri = $ctx->{builder}{nix_daemon_uri};
sub builder_store {
    my ($timeout, @cmd) = @_;
    return $ctx->capture_cmd($timeout, "nix-store", "--store", $builder_uri, @cmd);
}

my ($pg, $base_url, $grpc_addr) = start_queue_runner($ctx);
start_nix_daemon($ctx->{builder}, $pg, "builder daemon");
$pg->spawn("builder",
    ["hydra-builder", "--gateway-endpoint", "http://$grpc_addr"],
    env => {
        NIX_REMOTE    => $ctx->{builder}{nix_daemon_uri},
        NIX_CONF_DIR  => $ctx->{builder}{nix_conf_dir},
        NIX_STATE_DIR => $ctx->{builder}{nix_state_dir},
        NIX_STORE_DIR => $ctx->{builder}{nix_store_dir},
        RUST_LOG      => "hydra_builder=debug,info",
    },
);

my $ua = LWP::UserAgent->new(timeout => 2);

my $ok = eval {
    local $SIG{ALRM} = sub { die "timeout\n" };
    alarm 120;

    wait_for_url($ua, "$base_url/status")
        or die "queue-runner REST server did not come up\n";
    wait_for_url($ua, "$base_url/status/machines",
        sub { shift->decoded_content =~ /"hostname"/ })
        or die "builder did not register\n";

    my $req = HTTP::Request->new(POST => "$base_url/build_one");
    $req->header('Content-Type' => 'application/json');
    $req->content(encode_json({ buildId => $slow->id + 0 }));
    my $resp = $ua->request($req);
    $resp->is_success or die "submit failed: " . $resp->status_line . "\n";

    # Once `slow` enters its builder script, `input` has been pinned.
    until (-e $started) {
        $pg->pump_logs;
        select(undef, undef, undef, 0.1);
    }

    my ($gc_res, $gc_out, $gc_err) = builder_store(60, "--gc");
    is($gc_res, 0, "nix-store --gc on builder store succeeds")
        or diag($gc_err);

    my ($v_res, $v_out, $v_err) =
        builder_store(15, "--check-validity", $input_out);
    is($v_res, 0, "input is still valid in builder store after GC")
        or diag($v_err);

    write_text($proceed, "");
    wait_for_builds($ua, $base_url, $pg, $slow->id);

    alarm 0;
    1;
};
my $eval_err = $@;
alarm 0;
write_text($proceed, "") unless -e $proceed;
$pg->stop;
ok($ok, "orchestration completed") or diag($eval_err);

$slow->discard_changes;
is($slow->finished,    1, "slow build finished");
is($slow->buildstatus, 0, "slow build succeeded (input readable after GC)");

done_testing;

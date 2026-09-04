use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use IPC::Run;
use LWP::UserAgent;
use QueueRunnerContext;

# A build an evaluation needs, with `builds_during_evaluation = via-hydra`, must be
# built by the queue runner rather than inside the evaluator, and must
# land in the jobset being evaluated rather than anywhere generic.
#
# This drives `hydra-evaluator` itself rather than `hydra-eval-jobset`:
# the per-evaluation daemon lives in the former, so the usual
# CliRunners::evalSucceeds path would bypass everything under test.
#
# The fixture generates its own job list during evaluation, so the jobs
# exist at all only if that build really happened and was read back.

my $ctx = test_context(
    hydra_config => q|
builds_during_evaluation = via-hydra
|,
);

my $jobsetCtx = $ctx->makeJobset(expression => "builds-during-evaluation.nix");
my $jobset = $jobsetCtx->{"jobset"};
my $project_name = $jobsetCtx->{"project"}->name;
my $jobset_name = $jobset->name;

# queue_monitor_loop, because the Builds row appears part-way
# through the evaluation: there is nothing for a test to POST to
# /build_one ahead of time.
my ($pg, $base_url, $grpc_addr) = start_queue_runner($ctx, queue_monitor_loop => 1);

NixDaemon::start_nix_daemon($ctx->{builder}, $pg, "builder daemon");
$pg->spawn(
    "builder",
    [ "hydra-builder", "--gateway-endpoint", "http://$grpc_addr" ],
    env => {
        NIX_REMOTE    => $ctx->{builder}{nix_daemon_uri},
        NIX_CONF_DIR  => $ctx->{builder}{nix_conf_dir},
        NIX_STATE_DIR => $ctx->{builder}{nix_state_dir},
        NIX_STORE_DIR => $ctx->{builder}{nix_store_dir},
        RUST_LOG      => "hydra_builder=debug,info",
    },
);

# The evaluator proxies its reads and .drv uploads to a real
# nix-daemon; start_queue_runner already has one running on the central
# store. The URI carries the ?store= the daemon serves, which here is
# the logical store shared with the builder rather than /nix/store.
# It only exists once the context has picked a temp directory, hence
# appending to hydra.conf rather than passing it to test_context.
{
    open(my $fh, '>>', $ctx->{central}{hydra_config_file})
        or die "cannot append to hydra.conf: $!\n";
    print $fh "evaluation_upstream_daemon = $ctx->{central}{nix_daemon_uri}\n";
    close $fh;
}

my $ua = LWP::UserAgent->new(timeout => 2);
wait_for_url($ua, "$base_url/status/machines", sub {
    shift->decoded_content =~ /"hostname"/;
}) or die "Timed out waiting for builder to register\n";

# Run the evaluation, pumping the other processes' logs so a slow
# build doesn't look like a hung test.
my ($ev_in, $ev_out, $ev_err) = ("", "", "");
my $ev;
{
    local @ENV{keys %{$ctx->{central_env}}} = values %{$ctx->{central_env}};
    local $ENV{RUST_LOG} = "hydra_evaluator=debug,info";
    local $ENV{NO_COLOR} = "1";
    $ev = IPC::Run::start(
        [ "hydra-evaluator", $project_name, $jobset_name ],
        \$ev_in, \$ev_out, \$ev_err,
    );
}

my $deadline = time() + 300;
while (time() < $deadline) {
    $pg->pump_logs;
    eval { $ev->pump_nb };
    last if !$ev->pumpable;
    select(undef, undef, undef, 0.5);
}
if ($ev->pumpable) {
    eval { $ev->kill_kill };
    diag("hydra-evaluator stderr: $ev_err");
    die "timed out waiting for the evaluation to finish\n";
}
$ev->finish;
$pg->pump_logs;

# Routing the evaluation's NIX_REMOTE at the daemon routes *all* of its
# store traffic there, and hydra-eval-jobset copies the jobset's path
# inputs into the store before it needs to build anything. harmonia-protocol
# cannot deserialize the `fixed:r:sha256` content address that copy
# sends, so the connection dies before this test can assert anything.
# The failure is in harmonia's wire parsing, ahead of the point where
# the daemon would proxy the request, so there is nothing to work
# around on the Hydra side. Skip until harmonia grows support; the
# assertions below are what should hold once it does.
if ($ev_err =~ /unsupported digest algorithm/) {
    $pg->stop;
    skip_all(
        "harmonia-protocol cannot deserialize `fixed:r:sha256` content "
      . "addresses, which hydra-eval-jobset sends when copying path inputs"
    );
}

diag("hydra-evaluator stderr: $ev_err") if $ev_err ne "";

subtest "the derivation was built as a Hydra build" => sub {
    # Matched on drvPath rather than the job name: the request arrives as
    # BuildPaths, which knows only the derivation's store path, so the
    # row is named after that rather than after any job.
    my @eval_builds = $ctx->db->resultset('Builds')->search(
        { jobset_id => $jobset->id, drvpath => { like => '%-generated-job-list.drv' } },
        { order_by => 'id desc' },
    );

    is(scalar(@eval_builds), 1, "it produced exactly one build");

    my $build = $eval_builds[0];
    is($build->finished, 1, "the build finished");
    is($build->buildstatus, 0, "the build succeeded");
    is($build->keep, 1, "the build is kept, so its output survives gc");
};

subtest "the evaluation used the built output" => sub {
    $jobset->discard_changes({ '+columns' => { 'errormsg' => 'errormsg' } });
    is($jobset->has_error, 0, "jobset has no evaluation error");
    is($jobset->errormsg // "", "", "jobset error message is empty");

    my $eval = $jobset->jobsetevals->search({}, { order_by => 'id desc' })->first;
    ok($eval, "the jobset produced an evaluation");

    # Nothing checked in names these four: they came out of the
    # derivation the daemon built mid-evaluation, so the jobset having
    # exactly them is the end-to-end result.
    my @jobs = sort map { $_->job } $eval->jobs->all;
    is(\@jobs, [ "alpha", "beta", "delta", "gamma" ],
        "the generated job list became the jobset's jobs");
};

subtest "the build is under the evaluation but not among its jobs" => sub {
    my $eval = $jobset->jobsetevals->search({}, { order_by => 'id desc' })->first;

    my @for_eval = $eval->buildsForEvaluation->all;
    is(scalar(@for_eval), 1, "the evaluation has one build it needed to run");
    like($for_eval[0]->drvpath, qr/-generated-job-list\.drv$/,
        "it is the derivation the job list came from");

    # The distinction the forEvaluation column exists for: `builds` means
    # jobs, so restarting failures or filling a channel cannot pick this up.
    my @job_ids = map { $_->id } $eval->jobs->all;
    ok(!grep({ $_ == $for_eval[0]->id } @job_ids),
        "the build is not one of the evaluation's jobs");

    my $member = $ctx->db->resultset('JobsetEvalMembers')->find(
        { eval => $eval->id, build => $for_eval[0]->id });
    ok($member, "the build is a member of the evaluation");
    is($member->forevaluation, 1, "and is flagged as built for the evaluation");

    # Both memberships reach the API, under names that say which is which.
    my $json = $eval->TO_JSON;
    is($json->{buildsForEvaluation}, [ $for_eval[0]->id ],
        "it is listed in the evaluation's JSON");
    ok(!grep({ $_ == $for_eval[0]->id } @{$json->{builds}}),
        "and is not in the JSON's builds, which is still just the jobs");
};

$pg->stop;

done_testing;

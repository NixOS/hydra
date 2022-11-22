use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;
use File::Copy;
use Hydra::PostgresListener;
use Hydra::Event;

# expectEvent(Hydra::PostgresLister, name of the channel to expect, a sub which gets the parsed event)
sub expectEvent {
    my ($listener, $expectedChannel, $then) = @_;
    my $message = $listener->block_for_messages(0)->();

    my $channel = $message->{"channel"};

    if ($channel eq $expectedChannel) {
        my $event = Hydra::Event->new_event($message->{"channel"}, $message->{"payload"});
        local $_ = $event->{event};
        $then->();
    } else {
        is($expectedChannel, $channel, "Expecting a message on channel $channel");
    }
}


my $ctx = test_context(
    hydra_config => q|
# No caching for PathInput plugin, otherwise we get wrong values
# (as it has a 30s window where no changes to the file are considered).
path_input_cache_validity_seconds = 0
|
);

my $dbh = $ctx->db()->storage->dbh;
my $listener = Hydra::PostgresListener->new($dbh);

$listener->subscribe("build_queued");
$listener->subscribe("builds_added");
$listener->subscribe("cached_build_finished");
$listener->subscribe("cached_build_queued");
$listener->subscribe("eval_added");
$listener->subscribe("eval_cached");
$listener->subscribe("eval_failed");
$listener->subscribe("eval_started");


my $jobsetdir = $ctx->tmpdir . '/jobset';
mkdir($jobsetdir);
copy($ctx->jobsdir . '/hydra-eval-notifications.nix', "$jobsetdir/default.nix");

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "default.nix",
    jobsdir => $jobsetdir,
    build => 0
);
my $jobset = $builds->{"stable-job-queued"}->jobset;
my $evaluation = $builds->{"stable-job-queued"}->jobsetevals->first();

subtest "on the initial evaluation" => sub {
    expectEvent($listener, "eval_started", sub {
        isnt($_->{"trace_id"}, "", "We got a trace ID");
        is($_->{"jobset_id"}, $jobset->get_column('id'), "the jobset ID matches");
    });

    is($listener->block_for_messages(0)->()->{"channel"}, "build_queued", "expect 1/4 builds being queued");
    is($listener->block_for_messages(0)->()->{"channel"}, "build_queued", "expect 2/4 builds being queued");
    is($listener->block_for_messages(0)->()->{"channel"}, "build_queued", "expect 3/4 builds being queued");
    is($listener->block_for_messages(0)->()->{"channel"}, "build_queued", "expect 4/4 builds being queued");

    expectEvent($listener, "eval_added", sub {
        is($_->{"jobset_id"}, $jobset->get_column('id'), "the jobset ID matches");
        is($_->{"evaluation_id"}, $evaluation->get_column('id'), "the evaluation ID matches");
    });
    is($listener->block_for_messages(0)->()->{"channel"}, "builds_added", "new builds have been scheduled");
    is($listener->block_for_messages(0)->(), undef, "there are no more messages from the evaluator");
};

subtest "on a subsequent, totally cached / unchanged evaluation" => sub {
    ok(evalSucceeds($jobset), "evaluating for the second time");
    my $evaluation = $builds->{"stable-job-queued"}->jobsetevals->first();

    my $traceID;
    expectEvent($listener, "eval_started", sub {
        isnt($_->{"trace_id"}, "", "We got a trace ID");
        $traceID = $_->{"trace_id"};
        is($_->{"jobset_id"}, $jobset->get_column('id'), "the jobset ID matches");
    });

    expectEvent($listener, "eval_cached", sub {
        is($_->{"trace_id"}, $traceID, "Trace ID matches");
        is($_->{"jobset_id"}, $jobset->get_column('id'), "the jobset ID matches");
        is($_->{"evaluation_id"}, $evaluation->get_column('id'), "the evaluation ID matches");
    });

    is($listener->block_for_messages(0)->(), undef, "there are no more messages from the evaluator");
};

subtest "on a fresh evaluation with changed sources" => sub {
    open(my $fh, ">>", "${jobsetdir}/default.nix") or die "didn't open?";
    say $fh "\n";
    close $fh;

    ok(runBuild($builds->{"stable-job-passing"}), "building the stable passing job");
    $builds->{"stable-job-passing"}->discard_changes();

    ok(runBuild($builds->{"stable-job-failing"}), "building the stable failing job");
    $builds->{"stable-job-failing"}->discard_changes();

    ok(evalSucceeds($builds->{"variable-job"}->jobset), "evaluating for the third time");
    expectEvent($listener, "eval_started", sub {
        is($_->{"jobset_id"}, $jobset->get_column('id'), "the jobset ID matches");
    });

    # The order of builds is randomized when writing to the database,
    # so we can't expect the list in any specific order here.
    is(
        [sort(
            $listener->block_for_messages(0)->()->{"channel"},
            $listener->block_for_messages(0)->()->{"channel"},
            $listener->block_for_messages(0)->()->{"channel"},
            $listener->block_for_messages(0)->()->{"channel"}
        )],
        [
            # The `variable-job` build since it is the only one that is
            # totally different in this evaluation.
            "build_queued",

            # The next two are `stable-job-passing` and `stable-job-failing`,
            # since those are the two we explicitly built above
            "cached_build_finished",
            "cached_build_finished",

            # Finally, this should be `stable-job-queued` since we never
            # built it.
            "cached_build_queued",
        ],
        "we get a notice that a build is queued, one is still queued from a previous eval"
    );

    is($listener->block_for_messages(0)->()->{"channel"}, "eval_added", "a new evaluation was added");
    is($listener->block_for_messages(0)->()->{"channel"}, "builds_added", "a new build was added");
    is($listener->block_for_messages(0)->(), undef, "there are no more messages from the evaluator");
};

subtest "on a fresh evaluation with corrupted sources" => sub {
    open(my $fh, ">>", "${jobsetdir}/default.nix") or die "didn't open?";
    say $fh "this is not valid nix code!\n";
    close $fh;

    ok(evalFails($builds->{"variable-job"}->jobset), "evaluating the corrupted job");

    my $traceID;
    expectEvent($listener, "eval_started", sub {
        isnt($_->{"trace_id"}, "", "We got a trace ID");
        $traceID = $_->{"trace_id"};
        is($_->{"jobset_id"}, $jobset->get_column('id'), "the jobset ID matches");
    });

    expectEvent($listener, "eval_failed", sub {
        is($_->{"trace_id"}, $traceID, "Trace ID matches");
        is($_->{"jobset_id"}, $jobset->get_column('id'), "the jobset ID matches");
    });

    is($listener->block_for_messages(0)->(), undef, "there are no more messages from the evaluator");

};

done_testing;

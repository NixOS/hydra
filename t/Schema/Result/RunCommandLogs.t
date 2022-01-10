use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();
my $db = $ctx->db();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
);

my $build = $builds->{"empty_dir"};

sub new_run_log {
    return $db->resultset('RunCommandLogs')->create({
        job_matcher => "*:*:*",
        build_id => $build->get_column('id'),
        command => "bogus",
    });
}

subtest "Not yet started" => sub {
    my $runlog = new_run_log();

    is($runlog->start_time, undef, "The start time is undefined.");
    is($runlog->end_time, undef, "The start time is undefined.");
    is($runlog->exit_code, undef, "The exit code is undefined.");
    is($runlog->signal, undef, "The signal is undefined.");
    is($runlog->core_dumped, undef, "The core dump status is undefined.");
};

subtest "Completing a process before it is started is invalid" => sub {
    my $runlog = new_run_log();

    like(
        dies {
            $runlog->completed_with_child_error(0, 0);
        },
        qr/runcommandlogs_end_time_has_start_time/,
        "It is invalid to complete the process before it started"
    );
};

subtest "Starting a process" => sub {
    my $runlog = new_run_log();
    $runlog->started();
    is($runlog->did_succeed(), undef, "The process has not yet succeeded.");
    ok($runlog->is_running(), "The process is running.");
    ok(!$runlog->did_fail_with_signal(), "The process was not killed by a signal.");
    ok(!$runlog->did_fail_with_exec_error(), "The process did not fail to start due to an exec error.");
    is($runlog->start_time, within(time() - 1, 2), "The start time is recent.");
    is($runlog->end_time, undef, "The end time is undefined.");
    is($runlog->exit_code, undef, "The exit code is undefined.");
    is($runlog->signal, undef, "The signal is undefined.");
    is($runlog->core_dumped, undef, "The core dump status is undefined.");
};

subtest "The process completed (success)" => sub {
    my $runlog = new_run_log();
    $runlog->started();
    $runlog->completed_with_child_error(0, 123);
    ok($runlog->did_succeed(), "The process did succeed.");
    ok(!$runlog->is_running(), "The process is not running.");
    ok(!$runlog->did_fail_with_signal(), "The process was not killed by a signal.");
    ok(!$runlog->did_fail_with_exec_error(), "The process did not fail to start due to an exec error.");
    is($runlog->start_time, within(time() - 1, 2), "The start time is recent.");
    is($runlog->end_time, within(time() - 1, 2), "The end time is recent.");
    is($runlog->error_number, undef, "The error number is undefined");
    is($runlog->exit_code, 0, "The exit code is 0.");
    is($runlog->signal, undef, "The signal is undefined.");
    is($runlog->core_dumped, undef, "The core dump is undefined.");
};

subtest "The process completed (errored)" => sub {
    my $runlog = new_run_log();
    $runlog->started();
    $runlog->completed_with_child_error(21760, 123);
    ok(!$runlog->did_succeed(), "The process did not succeed.");
    ok(!$runlog->is_running(), "The process is not running.");
    ok(!$runlog->did_fail_with_signal(), "The process was not killed by a signal.");
    ok(!$runlog->did_fail_with_exec_error(), "The process did not fail to start due to an exec error.");
    is($runlog->start_time, within(time() - 1, 2), "The start time is recent.");
    is($runlog->end_time, within(time() - 1, 2), "The end time is recent.");
    is($runlog->error_number, undef, "The error number is undefined");
    is($runlog->exit_code, 85, "The exit code is 85.");
    is($runlog->signal, undef, "The signal is undefined.");
    is($runlog->core_dumped, undef, "The core dump is undefined.");
};

subtest "The process completed (status 15, child error 0)" => sub {
    my $runlog = new_run_log();
    $runlog->started();
    $runlog->completed_with_child_error(15, 0);
    ok(!$runlog->did_succeed(), "The process did not succeed.");
    ok(!$runlog->is_running(), "The process is not running.");
    ok($runlog->did_fail_with_signal(), "The process was killed by a signal.");
    ok(!$runlog->did_fail_with_exec_error(), "The process did not fail to start due to an exec error.");
    is($runlog->start_time, within(time() - 1, 2), "The start time is recent.");
    is($runlog->end_time, within(time() - 1, 2), "The end time is recent.");
    is($runlog->error_number, undef, "The error number is undefined");
    is($runlog->exit_code, undef, "The exit code is undefined.");
    is($runlog->signal, 15, "Signal 15 was sent.");
    is($runlog->core_dumped, 0, "There was no core dump.");
};

subtest "The process completed (signaled)" => sub {
    my $runlog = new_run_log();
    $runlog->started();
    $runlog->completed_with_child_error(393, 234);
    ok(!$runlog->did_succeed(), "The process did not succeed.");
    ok(!$runlog->is_running(), "The process is not running.");
    ok($runlog->did_fail_with_signal(), "The process was killed by a signal.");
    ok(!$runlog->did_fail_with_exec_error(), "The process did not fail to start due to an exec error.");
    is($runlog->start_time, within(time() - 1, 2), "The start time is recent.");
    is($runlog->end_time, within(time() - 1, 2), "The end time is recent.");
    is($runlog->error_number, undef, "The error number is undefined");
    is($runlog->exit_code, undef, "The exit code is undefined.");
    is($runlog->signal, 9, "The signal is 9.");
    is($runlog->core_dumped, 1, "The core dumped.");
};

subtest "The process failed to start" => sub {
    my $runlog = new_run_log();
    $runlog->started();
    $runlog->completed_with_child_error(-1, 2);
    ok(!$runlog->did_succeed(), "The process did not succeed.");
    ok(!$runlog->is_running(), "The process is running.");
    ok(!$runlog->did_fail_with_signal(), "The process was not killed by a signal.");
    ok($runlog->did_fail_with_exec_error(), "The process failed to start due to an exec error.");
    is($runlog->start_time, within(time() - 1, 2), "The start time is recent.");
    is($runlog->end_time, within(time() - 1, 2), "The end time is recent.");
    is($runlog->error_number, 2, "The error number is saved");
    is($runlog->exit_code, undef, "The exit code is undefined.");
    is($runlog->signal, undef, "The signal is undefined.");
    is($runlog->core_dumped, undef, "The core dumped is not defined.");
};

done_testing;

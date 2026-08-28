package Hydra::Helper::Evaluation;

# The little that the two halves of an evaluation have in common.
#
# Evaluating a jobset is two programs: `hydra-eval-jobset` decides what the
# evaluation is and queues a build to perform it, and `hydra-finish-eval`
# reads that build's result back. They share almost nothing -- one talks to
# the input plugins, the other to the jobs -- so what is left here is the
# handful of helpers that both genuinely need, rather than a common base.

use strict;
use warnings;
use Hydra::Helper::Email;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getPrevJobsetEval
    recordEvaluationFailure
    setJobsetError
);


# The most recent evaluation of a jobset, optionally only one that produced
# builds, or undef if there is none.
sub getPrevJobsetEval {
    my ($db, $jobset, $hasNewBuilds) = @_;
    my ($prevEval) = $jobset->jobsetevals(
        ($hasNewBuilds ? { hasnewbuilds => 1 } : { }),
        { order_by => "id DESC", rows => 1 });
    return $prevEval;
}


sub setJobsetError {
    my ($db, $config, $jobset, $errorMsg, $errorTime) = @_;
    my $prevError = $jobset->errormsg;

    eval {
        $db->txn_do(sub {
            $jobset->update({ errormsg => $errorMsg, errortime => $errorTime, fetcherrormsg => undef });
        });
    };
    if (defined $errorMsg && $errorMsg ne ($prevError // "") || $ENV{'HYDRA_MAIL_TEST'}) {
        sendJobsetErrorNotification($config, $jobset, $errorMsg);
    }
}


# Record that evaluating $jobset failed, and say so: the message on stderr,
# the message on the jobset, and an `eval_failed` notification. Returns the
# process's exit status, so a caller can `return` it directly.
#
# Shared because either half of an evaluation can be the one that fails, and
# neither should report it differently.
sub recordEvaluationFailure {
    my ($db, $config, $jobset, $checkError, $tmpId, $dryRun) = @_;

    return 0 unless $checkError;

    print STDERR $checkError;
    my $eventTime = time;
    $db->txn_do(sub {
        $jobset->update({lastcheckedtime => $eventTime});
        setJobsetError($db, $config, $jobset, $checkError, $eventTime);
        $db->storage->dbh->do("notify eval_failed, ?", undef, join("\t", $tmpId, $jobset->get_column('id')));
    }) if !$dryRun;

    return 1;
}


1;

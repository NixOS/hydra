package Hydra::Plugin::EmailNotificationEval;

use utf8;
use strict;
use warnings;
use parent 'Hydra::Plugin';
use Template;
use Hydra::Helper::Nix;
use Hydra::Helper::Email;
use Hydra::Config;

sub isEnabled {
    my ($self) = @_;
    return evalEmailNotificationEnabled($self->{config});
}

my $template = <<EOF;
Hi,

This is to let you know that evaluation of the Hydra jobset ‘[% project %]:[% jobset %]’
resulted in the following error:

[% errorMsg %]

Regards,

The Hydra build daemon.
EOF


# Report an evaluation error to the project's owner, once, when it differs from
# the error the jobset already had: a jobset that keeps failing the same way is
# not news. Whether it changed is not something this end can work out -- by the
# time the event arrives the jobset row holds the new error and the old one is
# gone -- so the evaluator decides and says so in the event.
sub _jobsetError {
    my ($self, $jobset, $errorChanged) = @_;

    # Whether there is anything to report is asked first, so that the usual
    # case -- an evaluation that went fine -- says nothing and does not go
    # looking up the project's owner.
    my $errorMsg = $jobset->errormsg;
    return unless defined $errorMsg;
    chomp $errorMsg;
    return if $errorMsg eq "";

    my $projectName = $jobset->get_column('project');
    my $jobsetName = $jobset->name;
    my $name = "$projectName:$jobsetName";

    # The remaining reasons for staying quiet are all about a jobset that *is*
    # broken, which is exactly when someone wonders why no mail arrived.
    unless ($ENV{'HYDRA_FORCE_SEND_MAIL'}) {
        unless ($errorChanged) {
            print STDERR "not sending mail about $name: its error has not changed\n";
            return;
        }
        if ($jobset->project->owner->emailonerror == 0) {
            print STDERR "not sending mail about $name: ${\$jobset->project->owner->username}"
                . " has not asked to hear about evaluation errors\n";
            return;
        }
    }

    my $body;
    Template->new({})->process(\$template,
        { project => $projectName, jobset => $jobsetName, errorMsg => $errorMsg },
        \$body)
        or die "failed to generate email from template";

    my $to = $jobset->project->owner->emailaddress;
    print STDERR "sending mail notification for evaluation error to ", $to, "\n";

    # Not caught, so that a mail server that is briefly unreachable fails the
    # task and it is retried with backoff, as a build notification is. The
    # jobset error this is about will still be there when it succeeds.
    sendEmail(
        $self->{config},
        $to,
        "Hydra $projectName:$jobsetName evaluation error",
        $body,
        [ 'X-Hydra-Project' => $projectName
        , 'X-Hydra-Jobset'  => $jobsetName
        ]);
}


sub evalFailed {
    my ($self, $traceID, $jobset, $errorChanged) = @_;
    $self->_jobsetError($jobset, $errorChanged);
}


# A successful evaluation can still have recorded an error, for the jobs within
# it that did not evaluate, and that is what this mail is most often about.
sub evalAdded {
    my ($self, $traceID, $jobset, $evaluation, $errorChanged) = @_;
    $self->_jobsetError($jobset, $errorChanged);
}


1;

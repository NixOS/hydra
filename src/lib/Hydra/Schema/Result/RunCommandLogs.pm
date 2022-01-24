use utf8;
package Hydra::Schema::Result::RunCommandLogs;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

Hydra::Schema::Result::RunCommandLogs

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 COMPONENTS LOADED

=over 4

=item * L<Hydra::Component::ToJSON>

=back

=cut

__PACKAGE__->load_components("+Hydra::Component::ToJSON");

=head1 TABLE: C<runcommandlogs>

=cut

__PACKAGE__->table("runcommandlogs");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0
  sequence: 'runcommandlogs_id_seq'

=head2 uuid

  data_type: 'uuid'
  is_nullable: 0
  size: 16

=head2 job_matcher

  data_type: 'text'
  is_nullable: 0

=head2 build_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 0

=head2 command

  data_type: 'text'
  is_nullable: 0

=head2 start_time

  data_type: 'integer'
  is_nullable: 1

=head2 end_time

  data_type: 'integer'
  is_nullable: 1

=head2 error_number

  data_type: 'integer'
  is_nullable: 1

=head2 exit_code

  data_type: 'integer'
  is_nullable: 1

=head2 signal

  data_type: 'integer'
  is_nullable: 1

=head2 core_dumped

  data_type: 'boolean'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_nullable       => 0,
    sequence          => "runcommandlogs_id_seq",
  },
  "uuid",
  { data_type => "uuid", is_nullable => 0, size => 16 },
  "job_matcher",
  { data_type => "text", is_nullable => 0 },
  "build_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 0 },
  "command",
  { data_type => "text", is_nullable => 0 },
  "start_time",
  { data_type => "integer", is_nullable => 1 },
  "end_time",
  { data_type => "integer", is_nullable => 1 },
  "error_number",
  { data_type => "integer", is_nullable => 1 },
  "exit_code",
  { data_type => "integer", is_nullable => 1 },
  "signal",
  { data_type => "integer", is_nullable => 1 },
  "core_dumped",
  { data_type => "boolean", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<runcommandlogs_uuid_unique>

=over 4

=item * L</uuid>

=back

=cut

__PACKAGE__->add_unique_constraint("runcommandlogs_uuid_unique", ["uuid"]);

=head1 RELATIONS

=head2 build

Type: belongs_to

Related object: L<Hydra::Schema::Result::Builds>

=cut

__PACKAGE__->belongs_to(
  "build",
  "Hydra::Schema::Result::Builds",
  { id => "build_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2022-01-24 10:24:52
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:ZVpYU6k3d/k/nitjpdgf/A

use POSIX qw(WEXITSTATUS WIFEXITED WIFSIGNALED WTERMSIG);
use Digest::SHA1 qw(sha1_hex);
use Hydra::Model::DB;

=head2 started

Update the row with the current timestamp as the start time.

=cut
sub started {
    my ($self) = @_;

    return $self->update({
      start_time => time()
    });
}

=head2 completed_with_child_error

Update the row with the current timestamp, exit code, core dump, errno,
and signal status.

Arguments:

=over 2

=item C<$child_error>

The value of $? or $CHILD_ERROR (with use English) after calling system().

=item C<$errno>

The value of $! or $ERRNO (with use English) after calling system().

=back

=cut
sub completed_with_child_error {
    my ($self, $child_error, $reported_errno) = @_;

    my $errno = undef;
    my $exit_code = undef;
    my $signal = undef;
    my $core_dumped = undef;

    if ($child_error == -1) {
      # -1 indicates `exec` failed, and this is the only
      # case where the reported errno is valid.
      #
      # The `+ 0` is because $! is a dual var and likes to be a string
      # if it can. +0 forces it to not be. Sigh.
      $errno = $reported_errno + 0;
    }

    if (WIFEXITED($child_error)) {
      # The exit status bits are only meaningful if the process exited
      $exit_code = WEXITSTATUS($child_error);
    }

    if (WIFSIGNALED($child_error)) {
      # The core dump and signal bits are only meaningful if the
      # process was terminated via a signal
      $signal = WTERMSIG($child_error);

      # This `& 128` comes from where Perl constructs the CHILD_ERROR
      # value:
      # https://github.com/Perl/perl5/blob/a9d7a07c2ebbfd8ee992f1d27ef4cfbed53085b6/perl.h#L3609-L3621
      #
      # The `+ 0` is handling another dualvar. It is a bool, but a
      # bool false is an empty string in boolean context and 0 in a
      # numeric concept. The ORM knows the column is a bool, but
      # does not treat the empty string as a bool when talking to
      # postgres.
      $core_dumped = (($child_error & 128) == 128) + 0;
    }

    return $self->update({
      end_time => time(),
      error_number => $errno,
      exit_code => $exit_code,
      signal => $signal,
      core_dumped => $core_dumped,
    });
}

=head2 did_succeed

Return:

* true if the task ran and finished successfully,
* false if the task did not run successfully but is completed
* undef if the task has not yet run

=cut
sub did_succeed {
    my ($self) = @_;

    if (!defined($self->end_time)) {
      return undef;
    }

    if (!defined($self->exit_code)) {
      return 0;
    }

    return $self->exit_code == 0;
}


=head2 is_running

Looks in the database to see if the task has been marked as completed.
Does not actually examine to see if the process is running anywhere.

Return:

* true if the task does not have a marked end date
* false if the task does have a recorded end
=cut
sub is_running {
    my ($self) = @_;

    return !defined($self->end_time);
}

=head2 did_fail_with_signal

Looks in the database to see if the task failed with a signal.

Return:

* true if the task is not running and failed with a signal.
* false if the task is running or exited with an exit code.
=cut
sub did_fail_with_signal {
    my ($self) = @_;

    if ($self->is_running()) {
      return 0;
    }

    if ($self->did_succeed()) {
      return 0;
    }

    return defined($self->signal);
}

=head2 did_fail_with_exec_error

Looks in the database to see if the task failed with a signal.

Return:

* true if the task is not running and failed with a signal.
* false if the task is running or exited with an exit code.
=cut
sub did_fail_with_exec_error {
    my ($self) = @_;

    if ($self->is_running()) {
      return 0;
    }

    if ($self->did_succeed()) {
      return 0;
    }

    return defined($self->error_number);
}

1;

=head2 log_relative_url

Returns the URL to the log file relative to the build it belongs to.

Return:

* The relative URL if a log file exists
* An empty string otherwise
=cut
sub log_relative_url() {
    my ($self) = @_;

    # Do not return a URL when there is no build yet
    if (not defined($self->start_time)) {
      return "";
    }

    my $sha = sha1_hex($self->command);
    # Do not return a URL when there is no log file yet
    if (not -f Hydra::Model::DB::getHydraPath . "/runcommand-logs/" . substr($sha, 0, 2) . "/$sha-" . $self->build_id) {
        return "";
    }

    return "runcommand-log/$sha";
}

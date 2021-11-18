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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-11-19 15:15:36
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:9AIzlQl1RjRXrs9gQCZKVw

use POSIX qw(WEXITSTATUS WIFEXITED WIFSIGNALED WTERMSIG);

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
      $core_dumped = ($child_error & 128) == 128;
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

1;

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


# Created by DBIx::Class::Schema::Loader v0.07049 @ 2021-11-18 12:35:52
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:N0G71diB8DNDgkYgaSQrFA



# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;

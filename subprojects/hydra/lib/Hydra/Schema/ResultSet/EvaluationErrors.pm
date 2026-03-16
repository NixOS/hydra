package Hydra::Schema::ResultSet::EvaluationErrors;

use strict;
use utf8;
use warnings;

use parent 'DBIx::Class::ResultSet';

use Storable qw(dclone);

__PACKAGE__->load_components('Helper::ResultSet::RemoveColumns');

# Exclude expensive error message values unless explicitly requested, and
# replace them with a summary field describing their presence/absence.
sub search_rs {
  my ( $class, $query, $attrs ) = @_;

  if ($attrs) {
    $attrs = dclone($attrs);
  }

  unless (exists $attrs->{'select'} || exists $attrs->{'columns'}) {
    $attrs->{'+columns'}->{'has_error'} = "errormsg != ''";
  }
  unless (exists $attrs->{'+columns'}->{'errormsg'}) {
    push @{ $attrs->{'remove_columns'} }, 'errormsg';
  }

  return $class->next::method($query, $attrs);
}

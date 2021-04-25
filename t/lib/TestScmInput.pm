package TestScmInput;
use warnings;
use strict;

use Exporter;
use Test2::V0;

use Setup;

our @ISA = qw(Exporter);
our @EXPORT = qw(testScmInput);

# Generic test for the various SCM types Hydra supports.
#
# Takes input in the form of:
#
# (
#   type => "input type",
#   name => "jobset name", # defaults to the input's type
#   uri => "uri",
#   update => "script for updating the input",
#   datadir => "data dir", # returned from `test_init()` subroutine
#   testdir => "the hydra tests directory", # usually just `getcwd`
# )
#
# and runs a test that constructs a jobset from the specified input.
sub testScmInput {
  # Collect named args, dying if a required arg is missing
  my %args = @_;
  my $type = $args{type} // die "required arg 'type' missing";
  my $expr = $args{expr} // die "required arg 'expr' missing";

  # $name is optional and defaults to $type
  my $name = $args{name} // $type;

  # Get directories
  my $testdir = $args{testdir} // die "required arg 'testdir' missing";
  my $datadir = $args{datadir} // die "required arg 'datadir' missing";
  my $jobsdir = $args{jobsdir} // die "required arg 'jobsdir' missing";

  my $update = $args{update} // die "required arg 'update' missing";
  $update = "$testdir/$update";

  # Create scratch locations
  my $scratchdir = "$datadir/scratch";
  mkdir $scratchdir or die "mkdir($scratchdir): $!\n";

  # $uri and $update are constructed from the directories
  my $uri = $args{uri} // die "required arg 'uri' missing";
  $uri = "file://$scratchdir/$uri";

  subtest "With the SCM input named $name" => sub {
    my $jobset = createJobsetWithOneInput($name, $expr, 'src', $type, $uri, $jobsdir);

    my ($mutations, $queueSize) = (0, 0);

    my ($loop, $updated) = updateRepository($name, $update, $scratchdir);
    while ($loop) {
      subtest "Mutation number $mutations" => sub {
        ok(evalSucceeds($jobset), "Evaluating nix-expression.");

        if ($updated) {
          $queueSize++;
          is(nrQueuedBuildsForJobset($jobset), $queueSize, "Expect $queueSize jobs in the queue.");
          ok(evalSucceeds($jobset), "Evaluating nix-expression again.");
        }

        is(nrQueuedBuildsForJobset($jobset), $queueSize, "Expect deterministic evaluation.");

        $mutations++;
        ($loop, $updated) = updateRepository($name, $update, $scratchdir);
      };
    }
  };
}

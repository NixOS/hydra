package Setup;

use strict;
use Exporter;
use Hydra::Helper::Nix;
use Hydra::Helper::AddBuilds;
use Cwd;

our @ISA = qw(Exporter);
our @EXPORT = qw(hydra_setup nrBuildsForJobset queuedBuildsForJobset nrQueuedBuildsForJobset createBaseJobset createJobsetWithOneInput evalSucceeds runBuild);

sub hydra_setup {
  my ($db) = @_;
  $db->resultset('Users')->create({ username => "root", emailaddress => 'root@email.com', password => '' });
}

sub nrBuildsForJobset {
  my ($jobset) = @_;
  return $jobset->builds->search({},{})->count ;
}

sub queuedBuildsForJobset {
  my ($jobset) = @_;
  return $jobset->builds->search({},{ join => 'schedulingInfo' });
}

sub nrQueuedBuildsForJobset {
  my ($jobset) = @_;
  return queuedBuildsForJobset($jobset)->count ;
}

sub createBaseJobset {
  my ($jobsetName, $nixexprpath) = @_;
  
  my $project = openHydraDB->resultset('Projects')->update_or_create({name => "tests", displayname => "", owner => "root"});
  my $jobset = $project->jobsets->create({name => $jobsetName, nixexprinput => "jobs", nixexprpath => $nixexprpath, emailoverride => ""});

  my $jobsetinput;
  my $jobsetinputals;

  $jobsetinput = $jobset->jobsetinputs->create({name => "jobs", type => "path"});
  $jobsetinputals = $jobsetinput->jobsetinputalts->create({altnr => 0, value => getcwd."/jobs"});

  return $jobset;
}

sub createJobsetWithOneInput {
  my ($jobsetName, $nixexprpath, $name, $type, $uri) = @_;
  my $jobset = createBaseJobset($jobsetName, $nixexprpath);

  my $jobsetinput;
  my $jobsetinputals;

  $jobsetinput = $jobset->jobsetinputs->create({name => $name, type => $type});
  $jobsetinputals = $jobsetinput->jobsetinputalts->create({altnr => 0, value => $uri});

  return $jobset;
}

sub evalSucceeds {
  my ($jobset) = @_;
  my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("../src/script/hydra-evaluator", $jobset->project->name, $jobset->name));
  chomp $stdout; chomp $stderr;
  print STDERR "Evaluation errors for jobset ".$jobset->project->name.":".$jobset->name.": \n".$jobset->errormsg."\n" if $jobset->errormsg;
  print STDERR "STDOUT: $stdout\n" if $stdout ne "";
  print STDERR "STDERR: $stderr\n" if $stderr ne "";
  return $res;
}

sub runBuild {
  my ($build) = @_;
  return captureStdoutStderr(60, ("../src/script/hydra-build", $build->id));
}

1;

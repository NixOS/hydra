package Hydra::Plugin::LatestOutputLink;

use strict;
use parent 'Hydra::Plugin';
use HTTP::Request;
use JSON;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;
use Data::Dump;

sub buildFinished {
  my ($self, $build, $dependents) = @_;

  # TODO: Lookup what these statuses are, these are just cribbed from
  # S3Backup
  return unless $build->buildstatus == 0 or $build->buildstatus == 6;

  my $jobName = showJobName $build;
  my $job = $build->job;

  my $cfg = $self->{config}->{latestoutput};
  my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

  my @matching_configs = ();
  foreach my $config (@config) {
      push @matching_configs, $config if $jobName =~ /^$config->{jobs}$/;
  }

  return unless @matching_configs;

  foreach my $config (@matching_configs) {
    my @buildoutputs = $build->buildoutputs;
    my $numBuildOutputs = @buildoutputs;

    if($numBuildOutputs != 1){
      print STDERR "WARNING: Not exactly 1 build outputs for job $jobName, not linking latest version\n";
      next;
    }

    my $output = $buildoutputs[0];
    my $outputPath = $output->path;
    my $linkLocation = $config->{path};
    my $linkTarget = $outputPath;

    print STDERR "INFO: Creating symlink at $linkLocation with target $linkTarget\n";
    if (-e $linkLocation) { unlink ($linkLocation); }
    my $linkCreated = symlink($linkTarget, $linkLocation);
    if($linkCreated == 1){
      if(defined $config->{touch}){
        system("touch", $config->{touch});
        if($? != 0){
          print STDERR "ERROR: calling 'touch $config->{touch}' failed\n";
        }
      }
    }else{
      print STDERR "ERROR: Failed to create symlink from $linkTarget to $linkLocation\n";
    }
  }
}

1;

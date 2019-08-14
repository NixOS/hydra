package Hydra::Plugin::RunCommand;

use strict;
use parent 'Hydra::Plugin';
use experimental 'smartmatch';
use JSON;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{runcommand};
}

sub configSectionMatches {
    my ($name, $project, $jobset, $job) = @_;

    my @elems = split ':', $name;

    die "invalid section name '$name'\n" if scalar(@elems) > 3;

    my $project2 = $elems[0] // "*";
    return 0 if $project2 ne "*" && $project ne $project2;

    my $jobset2 = $elems[1] // "*";
    return 0 if $jobset2 ne "*" && $jobset ne $jobset2;

    my $job2 = $elems[2] // "*";
    return 0 if $job2 ne "*" && $job ne $job2;

    return 1;
}

sub eventMatches {
    my ($conf, $event) = @_;
    for my $x (split " ", ($conf->{events} // "buildFinished")) {
        return 1 if $x eq $event;
    }
    return 0;
}

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $event = "buildFinished";

    my $cfg = $self->{config}->{runcommand};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    my $tmp;

    foreach my $conf (@config) {
        next unless eventMatches($conf, $event);
        next unless configSectionMatches(
            $conf->{job} // "*:*:*",
            $build->get_column('project'),
            $build->get_column('jobset'),
            $build->get_column('job'));

        my $command = $conf->{command} // die "<runcommand> section lacks a 'command' option";

        unless (defined $tmp) {
            $tmp = File::Temp->new(SUFFIX => '.json');

            my $json = {
                event => $event,
                build => $build->id,
                finished => $build->get_column('finished'),
                timestamp => $build->get_column('timestamp'),
                project => $build->get_column('project'),
                jobset => $build->get_column('jobset'),
                job => $build->get_column('job'),
                drvPath => $build->get_column('drvpath'),
                startTime => $build->get_column('starttime'),
                stopTime => $build->get_column('stoptime'),
                buildStatus => $build->get_column('buildstatus'),
                outputs => [],
                products => [],
                metrics => [],
            };

            for my $output ($build->buildoutputs) {
                my $j = {
                    name => $output->name,
                    path => $output->path,
                };
                push @{$json->{outputs}}, $j;
            }

            for my $product ($build->buildproducts) {
                my $j = {
                    productNr => $product->productnr,
                    type => $product->type,
                    subtype => $product->subtype,
                    fileSize => $product->filesize,
                    sha1hash => $product->sha1hash,
                    sha256hash => $product->sha256hash,
                    path => $product->path,
                    name => $product->name,
                    defaultPath => $product->defaultpath,
                };
                push @{$json->{products}}, $j;
            }

            for my $metric ($build->buildmetrics) {
                my $j = {
                    name => $metric->name,
                    unit => $metric->unit,
                    value => 0 + $metric->value,
                };
                push @{$json->{metrics}}, $j;
            }

            print $tmp encode_json($json) or die;
        }

        $ENV{"HYDRA_JSON"} = $tmp->filename;

        system("$command") == 0
            or warn "notification command '$command' failed with exit status $?\n";
    }
}

1;

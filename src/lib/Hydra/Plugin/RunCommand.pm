package Hydra::Plugin::RunCommand;

use strict;
use warnings;
use parent 'Hydra::Plugin';
use experimental 'smartmatch';
use JSON::MaybeXS;
use File::Basename qw(dirname);
use File::Path qw(make_path);
use IPC::Run3;
use Try::Tiny;

sub isEnabled {
    my ($self) = @_;

    return areStaticCommandsEnabled($self->{config}) || areDynamicCommandsEnabled($self->{config});
}

sub areStaticCommandsEnabled {
    my ($config) = @_;

    if (defined $config->{runcommand}) {
        return 1;
    }

    return 0;
}

sub areDynamicCommandsEnabled {
    my ($config) = @_;

    if ((defined $config->{dynamicruncommand})
        && $config->{dynamicruncommand}->{enable}) {
        return 1;
    }

    return 0;
}

sub isBuildEligibleForDynamicRunCommand {
    my ($build) = @_;

    if ($build->get_column("buildstatus") != 0) {
        return 0;
    }

    if ($build->get_column("job") =~ "^runCommandHook\..+") {
        my $out = $build->buildoutputs->find({name => "out"});
        if (!defined $out) {
            warn "DynamicRunCommand hook on " . $build->job . " (" . $build->id . ") rejected: no output named 'out'.";
            return 0;
        }

        my $path = $out->path;
        if (-l $path) {
            $path = readlink($path);
        }

        if (! -e $path) {
            warn "DynamicRunCommand hook on " . $build->job . " (" . $build->id . ") rejected: The 'out' output doesn't exist locally. This is a bug.";
            return 0;
        }

        if (! -x $path) {
            warn "DynamicRunCommand hook on " . $build->job . " (" . $build->id . ") rejected: The 'out' output is not executable.";
            return 0;
        }

        if (! -f $path) {
            warn "DynamicRunCommand hook on " . $build->job . " (" . $build->id . ") rejected: The 'out' output is not a regular file or symlink.";
            return 0;
        }

        if (! $build->jobset->enable_dynamic_run_command) {
            return 0;
        }

        if (! $build->project->enable_dynamic_run_command) {
            return 0;
        }

        return 1;
    }

    return 0;
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

sub fanoutToCommands {
    my ($config, $event, $build) = @_;

    my @commands;

    # Calculate all the statically defined commands to execute
    my $cfg = $config->{runcommand};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    foreach my $conf (@config) {
        my $matcher = $conf->{job} // "*:*:*";
        next unless eventMatches($conf, $event);
        next unless configSectionMatches(
            $matcher,
            $build->jobset->get_column('project'),
            $build->jobset->get_column('name'),
            $build->get_column('job')
        );

        if (!defined($conf->{command})) {
            warn "<runcommand> section for '$matcher' lacks a 'command' option";
            next;
        }

        push(@commands, {
            matcher => $matcher,
            command => $conf->{command},
        })
    }

    # Calculate all dynamically defined commands to execute
    if (areDynamicCommandsEnabled($config)) {
        if (isBuildEligibleForDynamicRunCommand($build)) {
            my $job = $build->get_column('job');
            my $out = $build->buildoutputs->find({name => "out"});
            push(@commands, {
                matcher => "DynamicRunCommand($job)",
                command => $out->path
            })
        }
    }

    return \@commands;
}

sub makeJsonPayload {
    my ($event, $build) = @_;
    my $json = {
        event => $event,
        build => $build->id,
        finished => $build->get_column('finished') ? JSON::MaybeXS::true : JSON::MaybeXS::false,
        timestamp => $build->get_column('timestamp'),
        project => $build->project->get_column('name'),
        jobset => $build->jobset->get_column('name'),
        job => $build->get_column('job'),
        drvPath => $build->get_column('drvpath'),
        startTime => $build->get_column('starttime'),
        stopTime => $build->get_column('stoptime'),
        buildStatus => $build->get_column('buildstatus'),
        nixName => $build->get_column('nixname'),
        system => $build->get_column('system'),
        homepage => $build->get_column('homepage'),
        description => $build->get_column('description'),
        license => $build->get_column('license'),
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

    return $json;
}

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    my $event = "buildFinished";

    my $commandsToRun = fanoutToCommands(
        $self->{config},
        $event,
        $build
    );

    if (@$commandsToRun == 0) {
        # No matching jobs, don't bother generating the JSON
        return;
    }

    my $tmp = File::Temp->new(SUFFIX => '.json');
    print $tmp encode_json(makeJsonPayload($event, $build)) or die;
    $ENV{"HYDRA_JSON"} = $tmp->filename;

    foreach my $commandToRun (@{$commandsToRun}) {
        my $command = $commandToRun->{command};

        # todo: make all the to-run jobs "unstarted" in a batch, then start processing
        my $runlog = $self->{db}->resultset("RunCommandLogs")->create({
            job_matcher => $commandToRun->{matcher},
            build_id => $build->get_column('id'),
            command => $command
        });

        $runlog->started();

        my $logPath = Hydra::Helper::Nix::constructRunCommandLogPath($runlog) or die "RunCommandLog not found.";
        my $dir = dirname($logPath);
        my $oldUmask = umask();
        my $f;

        try {
            # file: 640, dir: 750
            umask(0027);
            make_path($dir);

            open($f, '>', $logPath);
            umask($oldUmask);

            run3($command, \undef, $f, $f, { return_if_system_error => 1 }) == 1
                or warn "notification command '$command' failed with exit status $? ($!)\n";

            close($f);

            $runlog->completed_with_child_error($?, $!);
            1;
        } catch {
            die "Died while trying to process RunCommand (${\$runlog->uuid}): $_";
        } finally {
            umask($oldUmask);
        };
    }
}

1;

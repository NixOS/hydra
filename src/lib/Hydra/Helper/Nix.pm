package Hydra::Helper::Nix;

use strict;
use warnings;
use Exporter;
use File::Path;
use File::Basename;
use Hydra::Config;
use Hydra::Helper::CatalystUtils;
use Hydra::Model::DB;
use Nix::Store;
use Encode;
use Sys::Hostname::Long;
use IPC::Run;
use UUID4::Tiny qw(is_uuid4_string);

our @ISA = qw(Exporter);
our @EXPORT = qw(
    cancelBuilds
    constructRunCommandLogPath
    findLog
    gcRootFor
    getBaseUrl
    getDrvLogPath
    getEvals getMachines
    getGCRootsDir
    getHydraConfig
    getHydraHome
    getMainOutput
    getSCMCacheDir
    getStatsdConfig
    getStoreUri
    getTotalShares
    grab
    isLocalStore
    jobsetOverview
    jobsetOverview_
    pathIsInsidePrefix
    readIntoSocket
    readNixFile
    registerRoot
    restartBuilds
    run
    $MACHINE_LOCAL_STORE
    );

our $MACHINE_LOCAL_STORE = Nix::Store->new();


sub getHydraHome {
    my $dir = $ENV{"HYDRA_HOME"} or die "The HYDRA_HOME directory does not exist!\n";
    return $dir;
}

# Return hash of statsd configuration of the following shape:
# (
#   host => string,
#   port => digit
# )
sub getStatsdConfig {
    my ($config) = @_;
    my $cfg = $config->{statsd};
    my %statsd = defined $cfg ? ref $cfg eq "HASH" ? %$cfg : ($cfg) : ();

    return {
        "host" => $statsd{'host'}  // 'localhost',
        "port" => $statsd{'port'}  // 8125,
    }
}

sub getHydraNotifyPrometheusConfig {
    my ($config) = @_;
    my $cfg = $config->{hydra_notify};

    if (!defined($cfg)) {
        return undef;
    }

    if (ref $cfg ne "HASH") {
        print STDERR "Error reading Hydra's configuration file: hydra_notify should be a block.\n";
        return undef;
    }

    my $promcfg = $cfg->{prometheus};
    if (!defined($promcfg)) {
        return undef;
    }

    if (ref $promcfg ne "HASH") {
        print STDERR "Error reading Hydra's configuration file: hydra_notify.prometheus should be a block.\n";
        return undef;
    }

    if (defined($promcfg->{"listen_address"}) && defined($promcfg->{"port"})) {
        return {
            "listen_address" => $promcfg->{'listen_address'},
            "port" => $promcfg->{'port'},
        };
    } else {
        print STDERR "Error reading Hydra's configuration file: hydra_notify.prometheus should include listen_address and port.\n";
        return undef;
    }

    return undef;
}


sub getBaseUrl {
    my ($config) = @_;
    return $config->{'base_uri'} // "http://" . hostname_long . ":3000";
}


sub getSCMCacheDir {
    return Hydra::Model::DB::getHydraPath . "/scm" ;
}


sub getGCRootsDir {
    my $config = getHydraConfig();
    my $dir = $config->{gc_roots_dir};
    unless (defined $dir) {
        die unless defined $ENV{LOGNAME};
        $dir = ($ENV{NIX_STATE_DIR} || "/nix/var/nix" ) . "/gcroots/per-user/$ENV{LOGNAME}/hydra-roots";
    }
    mkpath $dir if !-e $dir;
    return $dir;
}


sub gcRootFor {
    my ($path) = @_;
    return getGCRootsDir . "/" . basename $path;
}


sub registerRoot {
    my ($path) = @_;
    my $link = gcRootFor $path;
    return if -e $link;
    open(my $root, ">", $link) or die "cannot create GC root `$link' to `$path'";
    close $root;
}


sub jobsetOverview_ {
    my ($c, $jobsets) = @_;
    return $jobsets->search({},
        { order_by => ["hidden ASC", "enabled DESC", "name"]
        , "+select" =>
          [ "(select count(*) from Builds as a where me.id = a.jobset_id and a.finished = 0 and a.isCurrent = 1)"
          , "(select count(*) from Builds as a where me.id = a.jobset_id and a.finished = 1 and buildstatus <> 0 and a.isCurrent = 1)"
          , "(select count(*) from Builds as a where me.id = a.jobset_id and a.finished = 1 and buildstatus = 0 and a.isCurrent = 1)"
          , "(select count(*) from Builds as a where me.id = a.jobset_id and a.isCurrent = 1)"
          ]
        , "+as" => ["nrscheduled", "nrfailed", "nrsucceeded", "nrtotal"]
        });
}


sub jobsetOverview {
    my ($c, $project) = @_;
    my $jobsets = $project->jobsets->search(isProjectOwner($c, $project) ? {} : { hidden => 0 });
    return jobsetOverview_($c, $jobsets);
}


# Return the path of the build log of the given derivation, or undef
# if the log is gone.
sub getDrvLogPath {
    my ($drvPath) = @_;
    my $base = basename $drvPath;
    my $bucketed = substr($base, 0, 2) . "/" . substr($base, 2);
    my $fn = Hydra::Model::DB::getHydraPath . "/build-logs/";
    for ($fn . $bucketed, $fn . $bucketed . ".bz2") {
        return $_ if -f $_;
    }
    for ($fn . $bucketed, $fn . $bucketed . ".zst") {
        return $_ if -f $_;
    }
    return undef;
}


# Find the log of the derivation denoted by $drvPath.  It it doesn't
# exist, try other derivations that produced its outputs (@outPaths).
sub findLog {
    my ($c, $drvPath, @outPaths) = @_;

    if (defined $drvPath) {
        my $logPath = getDrvLogPath($drvPath);
        return $logPath if defined $logPath;
    }

    return undef if scalar @outPaths == 0;

    # Filter out any NULLs. Content-addressed derivations
    # that haven't built yet or failed to build may have a NULL outPath.
    @outPaths = grep {defined} @outPaths;

    my @steps = $c->model('DB::BuildSteps')->search(
        { path => { -in => [@outPaths] } },
        { select => ["drvpath"]
        , distinct => 1
        , join => "buildstepoutputs"
        });

    foreach my $step (@steps) {
        next unless defined $step->drvpath;
        my $logPath = getDrvLogPath($step->drvpath);
        return $logPath if defined $logPath;
    }

    return undef;
}


sub getMainOutput {
    my ($build) = @_;
    return
        $build->buildoutputs->find({name => "out"}) //
        $build->buildoutputs->find({}, {limit => 1, order_by => ["name"]});
}


sub getEvalInputs {
    my ($c, $eval) = @_;
    my @inputs = $eval->jobsetevalinputs->search(
        { -or => [ -and => [ uri => { '!=' => undef }, revision => { '!=' => undef }], dependency => { '!=' => undef }], altNr => 0 },
        { order_by => "name" });
}


sub getEvalInfo {
    my ($cache, $eval) = @_;
    my $res = $cache->{$eval->id}; return $res if defined $res;

    # Get stats for this eval.
    my $nrScheduled;
    my $nrSucceeded = $eval->nrsucceeded;
    if (defined $nrSucceeded) {
        $nrScheduled = 0;
    } else {
        $nrScheduled = $eval->builds->search({finished => 0})->count;
        $nrSucceeded = $eval->builds->search({finished => 1, buildStatus => 0})->count;
        if ($nrScheduled == 0) {
            $eval->update({nrsucceeded => $nrSucceeded});
        }
    }

    # Get the inputs.
    my @inputsList = $eval->jobsetevalinputs->search(
        { -or => [ -and => [ uri => { '!=' => undef }, revision => { '!=' => undef }], dependency => { '!=' => undef }], altNr => 0 },
        { order_by => "name" });
    my $inputs;
    $inputs->{$_->name} = $_ foreach @inputsList;

    return $cache->{$eval->id} =
        { nrScheduled => $nrScheduled
        , nrSucceeded => $nrSucceeded
        , inputs => $inputs
        };
}


=head2 getEvals

This method returns a list of evaluations with details about what changed,
intended to be used with `eval.tt`.

Arguments:

=over 4

=item C<$c>
L<Hydra> - the entire application.

=item C<$evals_result_set>

A L<DBIx::Class::ResultSet> for the result class of L<Hydra::Model::DB::JobsetEvals>

=item C<$offset>

Integer offset when selecting evaluations

=item C<$rows>

Integer rows to fetch

=back

=cut
sub getEvals {
    my ($c, $evals_result_set, $offset, $rows) = @_;

    my $me = $evals_result_set->current_source_alias;

    my @evals = $evals_result_set->search(
        { hasnewbuilds => 1 },
        { order_by => "$me.id DESC", rows => $rows, offset => $offset });
    my @res = ();
    my $cache = {};

    foreach my $curEval (@evals) {

        my ($prevEval) = $c->model('DB::JobsetEvals')->search(
            { jobset_id => $curEval->get_column('jobset_id')
            , hasnewbuilds => 1, id => { '<', $curEval->id } },
            { order_by => "id DESC", rows => 1 });

        my $curInfo = getEvalInfo($cache, $curEval);
        my $prevInfo;
        $prevInfo = getEvalInfo($cache, $prevEval) if defined $prevEval;

        # Compute what inputs changed between each eval.
        my @changedInputs;
        foreach my $input (sort { $a->name cmp $b->name } values(%{$curInfo->{inputs}})) {
            my $p = $prevInfo->{inputs}->{$input->name};
            push @changedInputs, $input if
                !defined $p
                || ($input->revision || "") ne ($p->revision || "")
                || $input->type ne $p->type
                || ($input->uri || "") ne ($p->uri || "")
                || ($input->get_column('dependency') || "") ne ($p->get_column('dependency') || "");
        }

        push @res,
            { eval => $curEval
            , nrScheduled => $curInfo->{nrScheduled}
            , nrSucceeded => $curInfo->{nrSucceeded}
            , nrFailed => $curEval->nrbuilds - $curInfo->{nrSucceeded} - $curInfo->{nrScheduled}
            , diff => defined $prevEval ? $curInfo->{nrSucceeded} - $prevInfo->{nrSucceeded} : 0
            , changedInputs => [ @changedInputs ]
            };
    }

    return [@res];
}


sub getMachines {
    my %machines = ();

    my @machinesFiles = split /:/, ($ENV{"NIX_REMOTE_SYSTEMS"} || "/etc/nix/machines");

    for my $machinesFile (@machinesFiles) {
        next unless -e $machinesFile;
        open(my $conf, "<", $machinesFile) or die;
        while (my $line = <$conf>) {
            chomp($line);
            $line =~ s/\#.*$//g;
            next if $line =~ /^\s*$/;
            my @tokens = split /\s+/, $line;

            if (!defined($tokens[5]) || $tokens[5] eq "-") {
                $tokens[5] = "";
            }
            my @supportedFeatures = split(/,/, $tokens[5] || "");

            if (!defined($tokens[6]) || $tokens[6] eq "-") {
                $tokens[6] = "";
            }
            my @mandatoryFeatures = split(/,/, $tokens[6] || "");
            $machines{$tokens[0]} =
                { systemTypes => [ split(/,/, $tokens[1]) ]
                , sshKeys => $tokens[2]
                , maxJobs => int($tokens[3])
                , speedFactor => 1.0 * (defined $tokens[4] ? int($tokens[4]) : 1)
                , supportedFeatures => [ @supportedFeatures, @mandatoryFeatures ]
                , mandatoryFeatures => [ @mandatoryFeatures ]
                };
        }
        close $conf;
    }

    return \%machines;
}


# Check whether ‘$path’ is inside ‘$prefix’.  In particular, it checks
# that resolving symlink components of ‘$path’ never takes us outside
# of ‘$prefix’.  We use this to check that Nix build products don't
# refer to things outside of the Nix store (e.g. /etc/passwd) or to
# symlinks outside of the store that point into the store
# (e.g. /run/current-system).  Return undef or the resolved path.
sub pathIsInsidePrefix {
    my ($path, $prefix) = @_;
    my $n = 0;
    $path =~ s/\/+/\//g; # remove redundant slashes
    $path =~ s/\/*$//; # remove trailing slashes

    return undef unless $path eq $prefix || substr($path, 0, length($prefix) + 1) eq "$prefix/";

    my @cs = File::Spec->splitdir(substr($path, length($prefix) + 1));
    my $cur = $prefix;

    foreach my $c (@cs) {
        next if $c eq ".";

        # ‘..’ should not take us outside of the prefix.
        if ($c eq "..") {
            return undef if length($cur) <= length($prefix);
            $cur =~ s/\/[^\/]*$// or die; # remove last component
            next;
        }

        my $new = "$cur/$c";
        if (-l $new) {
            my $link = readlink $new or return undef;
            $new = substr($link, 0, 1) eq "/" ? $link : "$cur/$link";
            $new = pathIsInsidePrefix($new, $prefix);
            return undef unless defined $new;
        }
        $cur = $new;
    }

    return $cur;
}

sub readIntoSocket{
    my (%args) = @_;
    my $sock;

    eval {
        open($sock, "-|", @{$args{cmd}}) or die q(failed to open socket from command:\n $x);
    };

    return $sock;
}




sub run {
    my (%args) = @_;
    my $res = { stdout => "", stderr => "" };
    my $stdin = "";

    eval {
        local $SIG{ALRM} = sub { die "timeout\n" }; # NB: \n required
        alarm $args{timeout} if defined $args{timeout};
        my @x = ($args{cmd}, \$stdin, \$res->{stdout});
        push @x, \$res->{stderr} if $args{grabStderr} // 1;
        IPC::Run::run(@x,
            init => sub {
                chdir $args{dir} or die "changing to $args{dir}" if defined $args{dir};
                if (defined $args{env}) {
                    foreach my $key (keys %{$args{env}}) {
                        if (defined $args{env}->{$key}) {
                            $ENV{$key} = $args{env}->{$key};
                        } else {
                            delete $ENV{$key};
                        }
                    }
                }
            });
        alarm 0;
        $res->{status} = $?;
        chomp $res->{stdout} if $args{chomp} // 0;

        1;
    } or do {
        die unless $@ eq "timeout\n"; # propagate unexpected errors
        $res->{status} = -1;
        $res->{stderr} = "timeout\n";
    };

    return $res;
}


sub grab {
    my (%args) = @_;
    my $res = run(%args, grabStderr => 0);
    if ($res->{status}) {
        my $msgloc = "(in an indeterminate location)";
        if (defined $args{dir}) {
            $msgloc = "in $args{dir}";
        }
        die "command `@{$args{cmd}}' failed with exit status $res->{status} $msgloc";
    }
    return $res->{stdout};
}


sub getTotalShares {
    my ($db) = @_;
    return $db->resultset('Jobsets')->search(
        { 'project.enabled' => 1, 'me.enabled' => { '!=' => 0 } },
        { join => 'project', select => { sum => 'schedulingshares' }, as => 'sum' })->single->get_column('sum');
}


sub cancelBuilds {
    my ($db, $builds) = @_;
    return $db->txn_do(sub {
        $builds = $builds->search({ finished => 0 });
        my $n = $builds->count;
        my $time = time();
        $builds->update(
            { finished => 1,
            , iscachedbuild => 0, buildstatus => 4 # = cancelled
            , starttime => $time
            , stoptime => $time
            });
        return $n;
    });
}


sub restartBuilds {
    my ($db, $builds) = @_;

    $builds = $builds->search({ finished => 1 });

    foreach my $build ($builds->search({}, { columns => ["drvpath"] })) {
        next if !$MACHINE_LOCAL_STORE->isValidPath($build->drvpath);
        registerRoot $build->drvpath;
    }

    my $nrRestarted = 0;

    $db->txn_do(sub {
        # Reset the stats for the evals to which the builds belongs.
        # !!! Should do this in a trigger.
        $db->resultset('JobsetEvals')->search(
            { id => { -in => $builds->search({}, { join => { 'jobsetevalmembers' => 'eval' }, select => "jobsetevalmembers.eval", as => "eval", distinct => 1 })->as_query }
            })->update({ nrsucceeded => undef });

        # Clear the failed paths cache.
        # FIXME: Add this to the API.
        my $cleared = $db->resultset('FailedPaths')->search(
            { path => { -in => $builds->search({}, { join => "buildoutputs", select => "buildoutputs.path", as => "path", distinct => 1 })->as_query }
            })->delete;
        $cleared += $db->resultset('FailedPaths')->search(
            { path => { -in => $builds->search({}, { join => "buildstepoutputs", select => "buildstepoutputs.path", as => "path", distinct => 1 })->as_query }
            })->delete;
        print STDERR "cleared $cleared failed paths\n";

        $nrRestarted = $builds->update(
            { finished => 0
            , iscachedbuild => 0
            });
    });

    return $nrRestarted;
}


sub getStoreUri {
    my $config = getHydraConfig();
    return $config->{'server_store_uri'} // $config->{'store_uri'} // "auto";
}


# Read a file from the (possibly remote) nix store
sub readNixFile {
    my ($path) = @_;
    return grab(cmd => ["nix", "--experimental-features", "nix-command",
                        "store", "cat", "--store", getStoreUri(), "$path"]);
}


sub isLocalStore {
    my $uri = getStoreUri();
    return $uri =~ "^(local|daemon|auto|file)";
}


sub constructRunCommandLogPath {
    my ($runlog) = @_;
    my $uuid = $runlog->uuid;

    if (!is_uuid4_string($uuid)) {
        die "UUID was invalid."
    }

    my $hydra_path = Hydra::Model::DB::getHydraPath;
    my $bucket = substr($uuid, 0, 2);

    return "$hydra_path/runcommand-logs/$bucket/$uuid";
}

1;

package Setup;

use strict;
use Exporter;
use Test::PostgreSQL;
use File::Temp;
use File::Path qw(make_path);
use File::Basename;
use Cwd qw(abs_path getcwd);

our @ISA = qw(Exporter);
our @EXPORT = qw(test_init hydra_setup nrBuildsForJobset queuedBuildsForJobset
                 nrQueuedBuildsForJobset createBaseJobset createJobsetWithOneInput
                 evalSucceeds runBuild sendNotifications updateRepository
                 captureStdoutStderr);

# Set up the environment for running tests.
#
# Hash Parameters:
#
#  * hydra_config: configuration for the Hydra processes for your test.
#
# This clears several environment variables and sets them to ephemeral
# values: a temporary database, temporary Nix store, temporary Hydra
# data directory, etc.
#
# Note: This function must run _very_ early, before nearly any Hydra
# libraries are loaded. To use this, you very likely need to `use Setup`
# and then run `test_init`, and then `require` the Hydra libraries you
# need.
#
# It returns a tuple: a handle to a temporary directory and a handle to
# the postgres service. If either of these variables go out of scope,
# those resources are released and the test environment becomes invalid.
#
# Look at the top of an existing `.t` file to see how this should be used
# in practice.
sub test_init {
    my %opts = @_;

    my $dir = File::Temp->newdir();

    $ENV{'HYDRA_DATA'} = "$dir/hydra-data";
    mkdir $ENV{'HYDRA_DATA'};
    $ENV{'NIX_CONF_DIR'} = "$dir/nix/etc/nix";
    make_path($ENV{'NIX_CONF_DIR'});
    my $nixconf = "$ENV{'NIX_CONF_DIR'}/nix.conf";
    open(my $fh, '>', $nixconf) or die "Could not open file '$nixconf' $!";
    print $fh "sandbox = false\n";
    close $fh;

    $ENV{'HYDRA_CONFIG'} = "$dir/hydra.conf";

    open(my $fh, '>', $ENV{'HYDRA_CONFIG'}) or die "Could not open file '" . $ENV{'HYDRA_CONFIG'}. " $!";
    print $fh $opts{'hydra_config'} || "";
    close $fh;

    $ENV{'NIX_STATE_DIR'} = "$dir/nix/var/nix";
    $ENV{'NIX_STORE_DIR'} = "$dir/nix/store";
    $ENV{'NIX_LOG_DIR'} = "$dir/nix/var/log/nix";

    my $pgsql = Test::PostgreSQL->new(
        extra_initdb_args => "--locale C.UTF-8"
    );
    $ENV{'HYDRA_DBI'} = $pgsql->dsn;
    system("hydra-init") == 0 or die;
    return (
        db => $pgsql,
        tmpdir => $dir,
        testdir => abs_path(dirname(__FILE__) . "/.."),
        jobsdir => abs_path(dirname(__FILE__) . "/../jobs")
    );
}

sub captureStdoutStderr {
    # "Lazy"-load Hydra::Helper::Nix to avoid the compile-time
    # import of Hydra::Model::DB. Early loading of the DB class
    # causes fixation of the DSN, and we need to fixate it after
    # the temporary DB is setup.
    require Hydra::Helper::Nix;
    return Hydra::Helper::Nix::captureStdoutStderr(@_)
}

sub hydra_setup {
    my ($db) = @_;
    $db->resultset('Users')->create({ username => "root", emailaddress => 'root@invalid.org', password => '' });
}

sub nrBuildsForJobset {
    my ($jobset) = @_;
    return $jobset->builds->search({},{})->count ;
}

sub queuedBuildsForJobset {
    my ($jobset) = @_;
    return $jobset->builds->search({finished => 0});
}

sub nrQueuedBuildsForJobset {
    my ($jobset) = @_;
    return queuedBuildsForJobset($jobset)->count ;
}

sub createBaseJobset {
    my ($jobsetName, $nixexprpath, $jobspath) = @_;

    my $db = Hydra::Model::DB->new;
    my $project = $db->resultset('Projects')->update_or_create({name => "tests", displayname => "", owner => "root"});
    my $jobset = $project->jobsets->create({name => $jobsetName, nixexprinput => "jobs", nixexprpath => $nixexprpath, emailoverride => ""});

    my $jobsetinput;
    my $jobsetinputals;

    $jobsetinput = $jobset->jobsetinputs->create({name => "jobs", type => "path"});
    $jobsetinputals = $jobsetinput->jobsetinputalts->create({altnr => 0, value => $jobspath});

    return $jobset;
}

sub createJobsetWithOneInput {
    my ($jobsetName, $nixexprpath, $name, $type, $uri, $jobspath) = @_;
    my $jobset = createBaseJobset($jobsetName, $nixexprpath, $jobspath);

    my $jobsetinput;
    my $jobsetinputals;

    $jobsetinput = $jobset->jobsetinputs->create({name => $name, type => $type});
    $jobsetinputals = $jobsetinput->jobsetinputalts->create({altnr => 0, value => $uri});

    return $jobset;
}

sub evalSucceeds {
    my ($jobset) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-eval-jobset", $jobset->project->name, $jobset->name));
    chomp $stdout; chomp $stderr;
    print STDERR "Evaluation errors for jobset ".$jobset->project->name.":".$jobset->name.": \n".$jobset->errormsg."\n" if $jobset->errormsg;
    print STDERR "STDOUT: $stdout\n" if $stdout ne "";
    print STDERR "STDERR: $stderr\n" if $stderr ne "";
    return !$res;
}

sub runBuild {
    my ($build) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-queue-runner", "-vvvv", "--build-one", $build->id));
    if ($res) {
        print STDERR "Queue runner stdout: $stdout\n" if $stdout ne "";
        print STDERR "Queue runner stderr: $stderr\n" if $stderr ne "";
    }
    return !$res;
}

sub sendNotifications() {
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-notify", "--queued-only"));
    if ($res) {
        print STDERR "hydra notify stdout: $stdout\n" if $stdout ne "";
        print STDERR "hydra notify stderr: $stderr\n" if $stderr ne "";
    }
    return !$res;
}

sub updateRepository {
    my ($scm, $update, $scratchdir) = @_;
    my $curdir = getcwd;
    chdir "$scratchdir";
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ($update, $scm));
    chdir "$curdir";
    die "unexpected update error with $scm: $stderr\n" if $res;
    my ($message, $loop, $status) = $stdout =~ m/::(.*) -- (.*) -- (.*)::/;
    print STDOUT "Update $scm repository: $message\n";
    return ($loop eq "continue", $status eq "updated");
}

1;

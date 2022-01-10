package Setup;

use strict;
use warnings;
use Exporter;
use Test::PostgreSQL;
use File::Temp;
use File::Path qw(make_path);
use File::Basename;
use Cwd qw(abs_path getcwd);
use CliRunners;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    captureStdoutStderr
    createBaseJobset
    createJobsetWithOneInput
    evalFails
    evalSucceeds
    hydra_setup
    nrBuildsForJobset
    nrQueuedBuildsForJobset
    queuedBuildsForJobset
    runBuild
    sendNotifications
    test_context
    test_init
    updateRepository
    write_file
);

# Set up the environment for running tests.
#
# See HydraTestContext::new for documentation
sub test_context {
    require HydraTestContext;
    return HydraTestContext->new(@_);
}

# Set up the environment for running tests.
#
# See HydraTestContext::new for documentation
sub test_init {
    require HydraTestContext;
    my $ctx = HydraTestContext->new(@_);

    return (
        context => $ctx,
        tmpdir => $ctx->tmpdir,
        testdir => $ctx->testdir,
        jobsdir => $ctx->jobsdir
    )
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "Could not open file '$path' $!";
    print $fh $text || "";
    close $fh;
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

package Setup;

use strict;
use warnings;
use Exporter;
use Test::PostgreSQL;
use File::Temp;
use File::Path qw(make_path);
use File::Basename;
use Cwd qw(abs_path getcwd);
use Hydra::Helper::Exec;
use CliRunners;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    createBaseJobset
    createJobsetWithOneInput
    evalFails
    evalSucceeds
    hydra_setup
    nrBuildsForJobset
    nrQueuedBuildsForJobset
    queuedBuildsForJobset
    runBuild
    runBuilds
    sendNotifications
    setup_catalyst_test
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

# Set up Catalyst::Test with central_env applied. Exports wrapped `request()`,
# `get()`, etc. into the caller's namespace that apply central_env around each
# call.
#
# This is a really ugly trick, but I am not sure what else to do.
# `Catalyst::Test` uses `Sub::Exporter` to dynamically create these functions
# and inject them into the caller's scope (the idea is for `use Catalyst::Test
# 'MyApp';` to look deceptively simple). So instead of just calling a function
# that gets us a data structure with functions (object with methods, hash with
# function values, etc.) we are stuck doing this.
sub setup_catalyst_test {
    my ($ctx) = @_;
    my $caller = caller;
    my $central_env = $ctx->{central_env};

    # Import into a temporary namespace so we can capture the generated functions.
    {
        local @ENV{keys %$central_env} = values %$central_env;
        require Catalyst::Test;
        eval "package Setup::_catalyst_tmp; Catalyst::Test->import('Hydra');";
        die $@ if $@;
    }

    # Wrap all imported functions so central_env is applied around each call.
    for my $fn (qw(request ctx_request get content_like action_ok action_redirect action_notfound contenttype_is)) {
        no strict 'refs';
        my $orig = \&{"Setup::_catalyst_tmp::${fn}"};
        *{"${caller}::${fn}"} = sub {
            local @ENV{keys %$central_env} = values %$central_env;
            $orig->(@_);
        };
    }
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
    my ($db, $jobsetName, $nixexprpath, $jobspath) = @_;

    my $project = $db->resultset('Projects')->update_or_create({name => "tests", displayname => "", owner => "root"});
    my $jobset = $project->jobsets->create({name => $jobsetName, nixexprinput => "jobs", nixexprpath => $nixexprpath, emailoverride => ""});

    my $jobsetinput;
    my $jobsetinputals;

    $jobsetinput = $jobset->jobsetinputs->create({name => "jobs", type => "path"});
    $jobsetinputals = $jobsetinput->jobsetinputalts->create({altnr => 0, value => $jobspath});

    return $jobset;
}

sub createJobsetWithOneInput {
    my ($db, $jobsetName, $nixexprpath, $name, $type, $uri, $jobspath) = @_;
    my $jobset = createBaseJobset($db, $jobsetName, $nixexprpath, $jobspath);

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

use strict;
use warnings;

package HydraTestContext;
use File::Path qw(make_path);
use File::Basename;
use Cwd qw(abs_path getcwd);
use CliRunners;
use Hydra::Helper::Exec;

# Set up the environment for running tests.
#
# Hash Parameters:
#
#  * hydra_config: configuration for the Hydra processes for your test.
#  * nix_config: text to include in the test's nix.conf
#  * use_external_destination_store: Boolean indicating whether hydra should
#       use a destination store different from the evaluation store.
#       True by default.
# * before_init: a sub which is called after the database is up, but before
#       hydra-init is executed. It receives the HydraTestContext object as
#       its argument.
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
sub new {
    my ($class, %opts) = @_;

    # Cleanup will be managed by yath. By the default it will be cleaned
    # up, but can be kept to aid in debugging test failures.
    my $dir = File::Temp->newdir(CLEANUP => 0);

    $ENV{'HYDRA_DATA'} = "$dir/hydra-data";
    mkdir $ENV{'HYDRA_DATA'};
    $ENV{'NIX_CONF_DIR'} = "$dir/nix/etc/nix";
    make_path($ENV{'NIX_CONF_DIR'});
    my $nixconf = "$ENV{'NIX_CONF_DIR'}/nix.conf";
    my $nix_config = "sandbox = false\n" . ($opts{'nix_config'} || "");
    write_file($nixconf, $nix_config);
    $ENV{'HYDRA_CONFIG'} = "$dir/hydra.conf";

    my $hydra_config = $opts{'hydra_config'} || "";
    $hydra_config = "queue_runner_metrics_address = 127.0.0.1:0\n" . $hydra_config;
    if ($opts{'use_external_destination_store'} // 1) {
        $hydra_config = "store_uri = file://$dir/nix/dest-store\n" . $hydra_config;
    }

    write_file($ENV{'HYDRA_CONFIG'}, $hydra_config);

    my $nix_store_dir = "$dir/nix/store";
    my $nix_state_dir = "$dir/nix/var/nix";
    my $nix_log_dir = "$dir/nix/var/log/nix";

    $ENV{'NIX_REMOTE_SYSTEMS'} = '';
    $ENV{'NIX_REMOTE'} = "local?store=$nix_store_dir&state=$nix_state_dir&log=$nix_log_dir";
    $ENV{'NIX_STATE_DIR'} = $nix_state_dir; # FIXME: remove
    $ENV{'NIX_STORE_DIR'} = $nix_store_dir; # FIXME: remove

    my $pgsql = Test::PostgreSQL->new(
        extra_initdb_args => "--locale C.UTF-8"
    );
    $ENV{'HYDRA_DBI'} = $pgsql->dsn;

    my $self = bless {
        _db => undef,
        db_handle => $pgsql,
        tmpdir => $dir,
        nix_state_dir => $nix_state_dir,
        nix_log_dir => $nix_log_dir,
        testdir => abs_path(dirname(__FILE__) . "/.."),
        jobsdir => abs_path(dirname(__FILE__) . "/../jobs")
    }, $class;

    if ($opts{'before_init'}) {
        $opts{'before_init'}->($self);
    }

    expectOkay(5, ("hydra-init"));

    return $self;
}

sub db {
    my ($self, $setup) = @_;

    if (!defined $self->{_db}) {
        require Hydra::Schema;
        require Hydra::Model::DB;
        $self->{_db} = Hydra::Model::DB->new();

        if (!(defined $setup && $setup == 0)) {
            $self->{_db}->resultset('Users')->create({
                username => "root",
                emailaddress => 'root@invalid.org',
                password => ''
            });
        }
    }

    return $self->{_db};
}

sub tmpdir {
    my ($self) = @_;

    return $self->{tmpdir};
}

sub testdir {
    my ($self) = @_;

    return $self->{testdir};
}

sub jobsdir {
    my ($self) = @_;

    return $self->{jobsdir};
}

sub nix_state_dir {
    my ($self) = @_;

    return $self->{nix_state_dir};
}

# Create a jobset, evaluate it, and optionally build the jobs.
#
# In return, you get a hash of all the Builds records, keyed
# by their Nix attribute name.
#
# This always uses an `expression` from the `jobsdir` directory.
#
# Hash Parameters:
#
#  * expression: The file in the jobsdir directory to evaluate
#  * jobsdir: An alternative jobsdir to source the expression from
#  * build: Bool. Attempt to build all the resulting jobs. Default: false.
sub makeAndEvaluateJobset {
    my ($self, %opts) = @_;

    my $expression = $opts{'expression'} || die "Mandatory 'expression' option not passed to makeAndEvaluateJobset.\n";
    my $jobsdir = $opts{'jobsdir'} // $self->jobsdir;
    my $should_build = $opts{'build'} // 0;

    my $jobsetCtx = $self->makeJobset(
        expression => $expression,
        jobsdir => $jobsdir,
    );
    my $jobset = $jobsetCtx->{"jobset"};

    evalSucceeds($jobset) or die "Evaluating jobs/$expression should exit with return code 0.\n";

    my $builds = {};

    for my $build ($jobset->builds) {
        if ($should_build) {
            runBuild($build) or die "Build '".$build->job."' from jobs/$expression should exit with return code 0.\n";
            $build->discard_changes();
        }

        $builds->{$build->job} = $build;
    }

    return $builds;
}

# Create a jobset.
#
# In return, you get a hash of the user, project, and jobset records.
#
# This always uses an `expression` from the `jobsdir` directory.
#
# Hash Parameters:
#
#  * expression: The file in the jobsdir directory to evaluate
#  * jobsdir: An alternative jobsdir to source the expression from
sub makeJobset {
    my ($self, %opts) = @_;

    my $expression = $opts{'expression'} || die "Mandatory 'expression' option not passed to makeJobset.\n";
    my $jobsdir = $opts{'jobsdir'} // $self->jobsdir;

    # Create a new user for this test
    my $user = $self->db()->resultset('Users')->create({
        username => rand_chars(),
        emailaddress => rand_chars() . '@example.org',
        password => ''
    });

    # Create a new project for this test
    my $project = $self->db()->resultset('Projects')->create({
        name => rand_chars(),
        displayname => rand_chars(),
        owner => $user->username
    });

    # Create a new jobset for this test and set up the inputs
    my $jobset = $project->jobsets->create({
        name => rand_chars(),
        nixexprinput => "jobs",
        nixexprpath => $expression,
        emailoverride => ""
    });
    my $jobsetinput = $jobset->jobsetinputs->create({name => "jobs", type => "path"});
    $jobsetinput->jobsetinputalts->create({altnr => 0, value => $jobsdir});

    return {
        user => $user,
        project => $project,
        jobset => $jobset,
    };
}

sub DESTROY
{
    my ($self) = @_;
    $self->db(0)->schema->storage->disconnect();
    $self->{db_handle}->stop();
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "Could not open file '$path' $!\n.";
    print $fh $text || "";
    close $fh;
}

sub rand_chars {
    return sprintf("t%08X", rand(0xFFFFFFFF));
}

1;

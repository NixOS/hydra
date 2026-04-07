use strict;
use warnings;

package HydraTestContext;
use File::Path qw(make_path);
use File::Basename;
use File::Copy::Recursive qw(rcopy);
use File::Which qw(which);
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

    my $deststoredir;

    # Cleanup will be managed by yath. By the default it will be cleaned
    # up, but can be kept to aid in debugging test failures.
    my $dir = File::Temp->newdir(CLEANUP => 0);

    # Physical dirs for centralized services (queue runner, main web app, etc.)
    my $central = { root => "$dir/central" };
    $central->{hydra_data} = "$dir/hydra-data";
    $central->{nix_conf_dir} = "$dir/nix/etc/nix";
    $central->{hydra_config_file} = "$dir/hydra.conf";
    $central->{nix_store_dir} = "$central->{root}/nix/store";
    $central->{nix_state_dir} = "$central->{root}/nix/var/nix";
    $central->{nix_log_dir} = "$central->{root}/nix/var/log/nix";
    $central->{nix_store_uri} = "local?root=$central->{root}&store=$central->{nix_store_dir}";

    {
        mkdir $central->{hydra_data};
        make_path($central->{nix_conf_dir});
        my $nixconf = "$central->{nix_conf_dir}/nix.conf";
        my $nix_config = "sandbox = false\n" . ($opts{'nix_config'} || "");
        write_file($nixconf, $nix_config);

        my $hydra_config = $opts{'hydra_config'} || "";
        $hydra_config = "queue_runner_metrics_address = 127.0.0.1:0\n" . $hydra_config;
        if ($opts{'use_external_destination_store'} // 1) {
            $deststoredir = "$dir/nix/dest-store";
            $hydra_config = "store_uri = file://$dir/nix/dest-store\n" . $hydra_config;
        }

        write_file($central->{hydra_config_file}, $hydra_config);
    }

    my $pgsql = Test::PostgreSQL->new(
        extra_initdb_args => "--locale C.UTF-8"
    );
    $central->{hydra_dbi} = $pgsql->dsn;
    $central->{hydra_database_url} = $pgsql->uri;

    my $jobsdir = "$dir/jobs";
    rcopy(abs_path(dirname(__FILE__) . "/../jobs"), $jobsdir);

    my $coreutils_path = dirname(which 'install');
    replace_variable_in_file($jobsdir . "/config.nix", '@testPath@', $coreutils_path);
    replace_variable_in_file($jobsdir . "/declarative/project.json", '@jobsPath@', $jobsdir);

    my $self = bless {
        _db => undef,
        db_handle => $pgsql,
        tmpdir => $dir,
        central => $central,
        testdir => abs_path(dirname(__FILE__) . "/.."),
        jobsdir => $jobsdir,
        deststoredir => $deststoredir,

        # Env vars for central services (evaluator, hydra-init, hydra-notify, etc.).
        # Applied via local %ENV right before each process spawn.
        central_env => {
            'HYDRA_DATA'         => $central->{hydra_data},
            'HYDRA_CONFIG'       => $central->{hydra_config_file},
            'HYDRA_DBI'          => $central->{hydra_dbi},
            'HYDRA_DATABASE_URL' => $central->{hydra_database_url},
            'NIX_CONF_DIR'       => $central->{nix_conf_dir},
            'NIX_REMOTE_SYSTEMS' => '',
            'NIX_REMOTE'         => $central->{nix_store_uri},
            'NIX_STATE_DIR'      => $central->{nix_state_dir}, # FIXME: remove
            'NIX_STORE_DIR'      => $central->{nix_store_dir}, # FIXME: remove
        },
    }, $class;

    if ($opts{'before_init'}) {
        $opts{'before_init'}->($self);
    }

    $self->run_cmd(30, "hydra-init");

    return $self;
}

# Run a command with central_env applied.
# Dies on non-zero exit.
sub run_cmd {
    my ($self, $timeout, @cmd) = @_;
    local @ENV{keys %{$self->{central_env}}} = values %{$self->{central_env}};
    expectOkay($timeout, @cmd);
}

# Like run_cmd but returns ($exit, $stdout, $stderr) instead of dying.
sub capture_cmd {
    my ($self, $timeout, @cmd) = @_;
    local @ENV{keys %{$self->{central_env}}} = values %{$self->{central_env}};
    return captureStdoutStderr($timeout, @cmd);
}

sub db {
    my ($self, $setup) = @_;

    if (!defined $self->{_db}) {
        require Hydra::Schema;
        $self->{_db} = Hydra::Schema->connect($self->{central}{hydra_dbi});

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

    return $self->{central}{nix_state_dir};
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

    my $expression = $opts{'expression'};
    my $flake = $opts{'flake'};
    if (not $expression and not $flake) {
        die "One of 'expression' or 'flake' must be passed to makeEvaluateJobset.\n";
    }

    my $jobsdir = $opts{'jobsdir'} // $self->jobsdir;

    my %args = (
        jobsdir => $jobsdir,
    );
    if ($expression) {
        $args{expression} = $expression;
    }
    if ($flake) {
        $args{flake} = $flake;
    }
    my $jobsetCtx = $self->makeJobset(%args);

    return $self->evaluateJobset(
        jobset => $jobsetCtx->{"jobset"},
        expression => $expression,
        flake => $flake,
        build => $opts{"build"} // 0,
    )
}

sub evaluateJobset {
    my ($self, %opts) = @_;

    my $jobset = $opts{'jobset'};

    my $expression = $opts{'expression'} // $opts{'flake'};

    evalSucceeds($self, $jobset) or die "Evaluating jobs/$expression should exit with return code 0.\n";

    my $builds = {};

    my $should_build = $opts{'build'};

    my @all_builds = $jobset->builds;

    if ($should_build) {
        runBuilds($self, @all_builds) or die "Building jobs/$expression should exit with return code 0.\n";
    }

    for my $build (@all_builds) {
        $build->discard_changes() if $should_build;
        $builds->{$build->job} = $build;
    }

    return $builds;
}

# Create a jobset.
#
# In return, you get a hash of the user, project, and jobset records.
#
# This always uses an `expression` or `flake` from the `jobsdir` directory.
#
# Hash Parameters:
#
#  * expression: The file in the jobsdir directory to evaluate
#  * jobsdir: An alternative jobsdir to source the expression from
sub makeJobset {
    my ($self, %opts) = @_;

    my $expression = $opts{'expression'};
    my $flake = $opts{'flake'};
    if (not $expression and not $flake) {
        die "One of 'expression' or 'flake' must be passed to makeJobset.\n";
    }

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
    my %args = (
        name => rand_chars(),
        emailoverride => ""
    );
    if ($expression) {
        $args{type} = 0;
        $args{nixexprinput} = "jobs";
        $args{nixexprpath} = $expression;
    }
    if ($flake) {
        $args{type} = 1;
        $args{flake} = $flake;
    }
    my $jobset = $project->jobsets->create(\%args);
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
    $self->db(0)->storage->disconnect();
    $self->{db_handle}->stop();
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "Could not open file '$path' $!\n.";
    print $fh $text || "";
    close $fh;
}

sub replace_variable_in_file {
    my ($fn, $var, $val) = @_;

    open (my $input, '<', "$fn.in") or die $!;
    open (my $output, '>', $fn) or die $!;

    while (my $line = <$input>) {
        $line =~ s/$var/$val/g;
        print $output $line;
    }
}

sub rand_chars {
    return sprintf("t%08X", rand(0xFFFFFFFF));
}

1;

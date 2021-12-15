use strict;
use warnings;

package HydraTestContext;
use File::Path qw(make_path);
use File::Basename;
use Cwd qw(abs_path getcwd);

# Set up the environment for running tests.
#
# Hash Parameters:
#
#  * hydra_config: configuration for the Hydra processes for your test.
#  * nix_config: text to include in the test's nix.conf
#  * use_external_destination_store: Boolean indicating whether hydra should
#       use a destination store different from the evaluation store.
#       True by default.
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

    my $dir = File::Temp->newdir();

    $ENV{'HYDRA_DATA'} = "$dir/hydra-data";
    mkdir $ENV{'HYDRA_DATA'};
    $ENV{'NIX_CONF_DIR'} = "$dir/nix/etc/nix";
    make_path($ENV{'NIX_CONF_DIR'});
    my $nixconf = "$ENV{'NIX_CONF_DIR'}/nix.conf";
    my $nix_config = "sandbox = false\n" . ($opts{'nix_config'} || "");
    write_file($nixconf, $nix_config);
    $ENV{'HYDRA_CONFIG'} = "$dir/hydra.conf";

    my $hydra_config = $opts{'hydra_config'} || "";
    if ($opts{'use_external_destination_store'} // 1) {
        $hydra_config = "store_uri = file:$dir/nix/dest-store\n" . $hydra_config;
    }

    write_file($ENV{'HYDRA_CONFIG'}, $hydra_config);

    $ENV{'NIX_LOG_DIR'} = "$dir/nix/var/log/nix";
    $ENV{'NIX_REMOTE_SYSTEMS'} = '';
    $ENV{'NIX_REMOTE'} = '';
    $ENV{'NIX_STATE_DIR'} = "$dir/nix/var/nix";
    $ENV{'NIX_STORE_DIR'} = "$dir/nix/store";

    my $pgsql = Test::PostgreSQL->new(
        extra_initdb_args => "--locale C.UTF-8"
    );
    $ENV{'HYDRA_DBI'} = $pgsql->dsn;
    system("hydra-init") == 0 or die;

    my $self = {
        _db => undef,
        db_handle => $pgsql,
        tmpdir => $dir,
        testdir => abs_path(dirname(__FILE__) . "/.."),
        jobsdir => abs_path(dirname(__FILE__) . "/../jobs")
    };

    return bless $self, $class;
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

sub DESTROY
{
    my ($self) = @_;
    $self->db(0)->schema->storage->disconnect();
    $self->{db_handle}->stop();
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "Could not open file '$path' $!";
    print $fh $text || "";
    close $fh;
}

1;

use strict;
use warnings;

package LDAPContext;
use POSIX qw(SIGKILL);
use File::Path qw(make_path);
use WWW::Form::UrlEncoded::PP qw();
use Hydra::Helper::Exec;

# Set up an LDAP server to run during the test.
#
# It creates a top level organization and structure, and provides
# add_user and add_group.
#
# The server is automatically terminated when the class is dropped.
sub new {
    my ($class) = @_;

    my $root = File::Temp->newdir();
    mkdir $root;

    my $pid_file = "$root/slapd.pid";

    my $slapd_dir = "$root/slap.d";
    mkdir $slapd_dir;

    my $db_dir = "$root/db";
    mkdir $db_dir;

    my $socket = "$root/slapd.socket";

    my $self = {
        _db_dir => $db_dir,
        _openldap_source => $ENV{"OPENLDAP_ROOT"},
        _pid_file => $pid_file,
        _slapd_dir => $slapd_dir,
        _socket => $socket,
        _tmpdir => $root,
    };

    my $blessed = bless $self, $class;
    $blessed->start();

    return $blessed;
}

# Create a user with a specific email address and password
#
# Hash Parameters:
#
#  * password: The clear text password, will be hashed when stored in the DB.
#  * email:    The user's email address. Defaults to $name@example.net
#
# Return: a hash of parameters for the user
#
# * username:        The user's provided $name
# * password:        The plaintext password, generated if not provided in the arguments
# * hashed_password: The hashed password
# * email:           Their email address
sub add_user {
    my ($self, $name, %opts) = @_;

    my $email = $opts{'email'} // "$name\@example";
    my $password = $opts{'password'} // rand_chars();

    my ($res, $stdout, $stderr) = captureStdoutStderr(1, ("slappasswd", "-s", $password));
    if ($res) {
        die "Failed to execute slappasswd ($res): $stderr, $stdout";
    }
    my $hashedPassword = $stdout;
    $hashedPassword =~ s/^\s+|\s+$//g; # Trim whitespace

    $self->load_ldif("dc=example", <<LDIF);
dn: cn=$name,ou=users,dc=example
objectClass: organizationalPerson
objectClass: inetOrgPerson
sn: $name
cn: $name
mail: $email
userPassword: $hashedPassword
LDIF

    return {
        username => $name,
        email => $email,
        password => $password,
        hashed_password => $hashedPassword,
    };
}

# Create a group with a specific name and members
sub add_group {
    my ($self, $name, @users) = @_;

    my $members = join "\n", (map "member: cn=$_,ou=users,dc=example", @users);

    $self->load_ldif("dc=example", <<LDIF);
dn: cn=$name,ou=groups,dc=example
cn: $name
description: User group $name
objectClass: groupOfNames
$members
LDIF
}

sub _makeBootstrapConfig {
    my ($self) = @_;
    # This has been copied from the generated config used by the
    # ldap test in the flake.nix.
    return <<EOF;
dn: cn=config
cn: config
objectClass: olcGlobal
olcPidFile: ${\$self->{"_pid_file"}}

dn: cn=schema,cn=config
cn: schema
objectClass: olcSchemaConfig

include: file://${\$self->{"_openldap_source"}}/etc/schema/core.ldif
include: file://${\$self->{"_openldap_source"}}/etc/schema/cosine.ldif
include: file://${\$self->{"_openldap_source"}}/etc/schema/inetorgperson.ldif
include: file://${\$self->{"_openldap_source"}}/etc/schema/nis.ldif

dn: olcDatabase={1}mdb,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMdbConfig
olcDatabase: {1}mdb
olcDbDirectory: ${\$self->{"_db_dir"}}
olcRootDN: cn=root,dc=example
olcRootPW: notapassword
olcSuffix: dc=example
EOF
}

sub _makeBootstrapOrganization {
    my ($self) = @_;
    # This has been copied from the generated config used by the
    # ldap test in the flake.nix.
    return <<EOF;
dn: dc=example
dc: example
o: Root
objectClass: top
objectClass: dcObject
objectClass: organization

dn: ou=users,dc=example
ou: users
description: All users
objectClass: top
objectClass: organizationalUnit

dn: ou=groups,dc=example
ou: groups
description: All groups
objectClass: top
objectClass: organizationalUnit
EOF
}

sub start {
    my ($self) = @_;

    $self->load_ldif("cn=config", $self->_makeBootstrapConfig());
    $self->load_ldif("dc=example", $self->_makeBootstrapOrganization());

    $self->_spawn()
}

sub validateConfig {
    my ($self) = @_;

    expectOkay(1, ("slaptest", "-u", "-F", $self->{"_slapd_dir"}));
}

sub _spawn {
    my ($self) = @_;

    my $pid = fork;
    die "When starting the LDAP server: failed to fork." if not defined $pid;

    if ($pid == 0) {
        exec("${\$self->{'_openldap_source'}}/libexec/slapd",
            # A debug flag `-d` must be specified to avoid backgrounding, and an empty
            # argument means no additional debugging.
            "-d", "",
            #  "-d", "conns", "-d", "filter", "-d", "config",
         "-F", $self->{"_slapd_dir"}, "-h", $self->server_url()) or die "Could not start slapd";
    } else {
        $self->{"_pid"} = $pid;
    }
}

sub server_url {
    my ($self) = @_;

    my $encoded_socket_path = WWW::Form::UrlEncoded::PP::url_encode($self->{"_socket"});

    return "ldapi://$encoded_socket_path";
}

sub tmpdir {
    my ($self) = @_;

    return $self->{"_tmpdir"};
}

sub load_ldif {
    my ($self, $suffix, $content) = @_;

    my $path = "${\$self->{'_tmpdir'}}/load.ldif";
    write_file($path, $content);
    expectOkay(1, ("slapadd", "-F", $self->{"_slapd_dir"}, "-b", $suffix, "-l", $path));
    $self->validateConfig();
}

sub DESTROY
{
    my ($self) = @_;
    if ($self->{"_pid"}) {
        kill SIGKILL, $self->{"_pid"};
    }
}

sub write_file {
    my ($path, $text) = @_;
    open(my $fh, '>', $path) or die "Could not open file '$path' $!";
    print $fh $text || "";
    close $fh;
}

sub rand_chars {
    return sprintf("t%08X", rand(0xFFFFFFFF));
}

1;

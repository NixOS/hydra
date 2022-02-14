use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json encode_json);

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');
use HTTP::Request::Common qw(POST PUT GET DELETE);

# This test verifies that creating, reading, updating, and deleting a jobset via
# the HTTP API works as expected.

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Create a user to log in to
my $user =
  $db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

my $project = $db->resultset('Projects')->create({ name => 'tests', displayname => 'Tests', owner => 'alice' });

# Login and save cookie for future requests
my $req = request(
    POST '/login',
    Referer => 'http://localhost/',
    Content => {
        username => 'alice',
        password => 'foobar'
    }
);
is($req->code, 302);
my $cookie = $req->header("set-cookie");

subtest 'Create new jobset "job" as flake type' => sub {
    my $jobsetcreate = request(
        PUT '/jobset/tests/job',
        Accept       => 'application/json',
        Content_Type => 'application/json',
        Cookie       => $cookie,
        Content      => encode_json(
            {
                enabled          => 2,
                visible          => JSON::MaybeXS::true,
                name             => "job",
                type             => 1,
                description      => "test jobset",
                flake            => "github:nixos/nix",
                checkinterval    => 0,
                schedulingshares => 100,
                keepnr           => 3
            }
        )
    );
    ok($jobsetcreate->is_success);
    is($jobsetcreate->header("location"), "http://localhost/jobset/tests/job");
};

subtest 'Read newly-created jobset "job"' => sub {
    my $jobsetinfo = request(GET '/jobset/tests/job', Accept => 'application/json',);
    ok($jobsetinfo->is_success);
    is(
        decode_json($jobsetinfo->content),
        {
            checkinterval    => 0,
            description      => "test jobset",
            emailoverride    => "",
            enabled          => 2,
            enableemail      => JSON::MaybeXS::false,
            errortime        => undef,
            errormsg         => "",
            fetcherrormsg    => "",
            flake            => "github:nixos/nix",
            visible          => JSON::MaybeXS::true,
            inputs           => {},
            keepnr           => 3,
            lastcheckedtime  => undef,
            name             => "job",
            nixexprinput     => "",
            nixexprpath      => "",
            project          => "tests",
            schedulingshares => 100,
            starttime        => undef,
            triggertime      => undef,
            type             => 1
        }
    );
};

subtest 'Update jobset "job" to legacy type' => sub {
    my $jobsetupdate = request(
        PUT '/jobset/tests/job',
        Accept       => 'application/json',
        Content_Type => 'application/json',
        Cookie       => $cookie,
        Content      => encode_json(
            {
                enabled      => 3,
                visible      => JSON::MaybeXS::true,
                name         => "job",
                type         => 0,
                nixexprinput => "ofborg",
                nixexprpath  => "release.nix",
                inputs       => {
                    ofborg => {
                        name  => "ofborg",
                        type  => "git",
                        value => "https://github.com/NixOS/ofborg.git released"
                    }
                },
                description      => "test jobset",
                checkinterval    => 0,
                schedulingshares => 50,
                keepnr           => 1
            }
        )
    );
    ok($jobsetupdate->is_success);

    # Read newly-updated jobset "job"
    my $jobsetinfo = request(GET '/jobset/tests/job', Accept => 'application/json',);
    ok($jobsetinfo->is_success);
    is(
        decode_json($jobsetinfo->content),
        {
            checkinterval => 0,
            description   => "test jobset",
            emailoverride => "",
            enabled       => 3,
            enableemail   => JSON::MaybeXS::false,
            errortime     => undef,
            errormsg      => "",
            fetcherrormsg => "",
            flake         => "",
            visible       => JSON::MaybeXS::true,
            inputs        => {
                ofborg => {
                    name             => "ofborg",
                    type             => "git",
                    emailresponsible => JSON::MaybeXS::false,
                    value            => "https://github.com/NixOS/ofborg.git released"
                }
            },
            keepnr           => 1,
            lastcheckedtime  => undef,
            name             => "job",
            nixexprinput     => "ofborg",
            nixexprpath      => "release.nix",
            project          => "tests",
            schedulingshares => 50,
            starttime        => undef,
            triggertime      => undef,
            type             => 0
        }
    );
};

subtest 'Update jobset "job" to have an invalid input type' => sub {
    my $jobsetupdate = request(
        PUT '/jobset/tests/job',
        Accept       => 'application/json',
        Content_Type => 'application/json',
        Cookie       => $cookie,
        Content      => encode_json(
            {
                enabled      => 3,
                visible      => JSON::MaybeXS::true,
                name         => "job",
                type         => 0,
                nixexprinput => "ofborg",
                nixexprpath  => "release.nix",
                inputs       => {
                    ofborg => {
                        name  => "ofborg",
                        type  => "123",
                        value => "https://github.com/NixOS/ofborg.git released"
                    }
                },
                description      => "test jobset",
                checkinterval    => 0,
                schedulingshares => 50,
                keepnr           => 1
            }
        )
    );
    ok(!$jobsetupdate->is_success);
    ok($jobsetupdate->content =~ m/Invalid input type.*valid types:/);
};

subtest 'Delete jobset "job"' => sub {
    my $jobsetinfo = request(
        DELETE '/jobset/tests/job',
        Accept => 'application/json',
        Cookie => $cookie
    );
    ok($jobsetinfo->is_success);

    # Jobset "job" should no longer exist.
    $jobsetinfo = request(GET '/jobset/tests/job', Accept => 'application/json',);
    ok(!$jobsetinfo->is_success);
};

done_testing;

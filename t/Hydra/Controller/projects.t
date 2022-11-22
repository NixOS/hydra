use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json encode_json);

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;
use HTTP::Request::Common;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

# Create a user to log in to
my $user = $db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "Tests", owner => "root"});

# Login and save cookie for future requests
my $req = request(POST '/login',
    Referer => 'http://localhost/',
    Content => {
        username => 'alice',
        password => 'foobar'
    }
);
is($req->code, 302);
my $cookie = $req->header("set-cookie");

subtest "Read project 'tests'" => sub {
    my $projectinfo = request(GET '/project/tests',
        Accept => 'application/json',
    );

    ok($projectinfo->is_success);
    is(decode_json($projectinfo->content), {
        description => "",
        displayname => "Tests",
        enabled => JSON::MaybeXS::true,
        enable_dynamic_run_command => JSON::MaybeXS::false,
        hidden => JSON::MaybeXS::false,
        homepage => "",
        jobsets => [],
        name => "tests",
        owner => "root",
        "private" => JSON::MaybeXS::false
    });
};

subtest "Transitioning from declarative project to normal" => sub {
    subtest "Make project declarative" => sub {
        my $projectupdate = request(PUT '/project/tests',
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
            Content => encode_json({
                enabled => JSON::MaybeXS::true,
                visible => JSON::MaybeXS::true,
                name => "tests",
                displayname => "Tests",
                declarative => {
                    file => "bogus",
                    type => "boolean",
                    value => "false"
                }
            })
        );
        ok($projectupdate->is_success);
    };

    subtest "Project has '.jobsets' jobset" => sub {
        my $projectinfo = request(GET '/project/tests',
            Accept => 'application/json',
        );

        ok($projectinfo->is_success);
        is(decode_json($projectinfo->content), {
            description => "",
            displayname => "Tests",
            enabled => JSON::MaybeXS::true,
            enable_dynamic_run_command => JSON::MaybeXS::false,
            hidden => JSON::MaybeXS::false,
            homepage => "",
            jobsets => [".jobsets"],
            name => "tests",
            owner => "root",
            declarative => {
                file => "bogus",
                type => "boolean",
                value => "false"
            },
            "private" => JSON::MaybeXS::false
        });
    };

    subtest "Make project normal" => sub {
        my $projectupdate = request(PUT '/project/tests',
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
            Content => encode_json({
                enabled => JSON::MaybeXS::true,
                visible => JSON::MaybeXS::true,
                name => "tests",
                displayname => "Tests",
                declarative => {
                    file => "",
                    type => "boolean",
                    value => "false"
                }
            })
        );
        ok($projectupdate->is_success);
    };

    subtest "Project doesn't have '.jobsets' jobset" => sub {
        my $projectinfo = request(GET '/project/tests',
            Accept => 'application/json',
        );

        ok($projectinfo->is_success);
        is(decode_json($projectinfo->content), {
            description => "",
            displayname => "Tests",
            enabled => JSON::MaybeXS::true,
            enable_dynamic_run_command => JSON::MaybeXS::false,
            hidden => JSON::MaybeXS::false,
            homepage => "",
            jobsets => [],
            name => "tests",
            owner => "root",
            "private" => JSON::MaybeXS::false
        });
    };
};

done_testing;

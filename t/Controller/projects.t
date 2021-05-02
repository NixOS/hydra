use feature 'unicode_strings';
use strict;
use Setup;
use JSON qw(decode_json);

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

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $projectinfo = request(GET '/project/tests',
    Accept => 'application/json',
);

ok($projectinfo->is_success);
is(decode_json($projectinfo->content), {
    description => "",
    displayname => "",
    enabled => JSON::true,
    hidden => JSON::false,
    homepage => "",
    jobsets => [],
    name => "tests",
    owner => "root",
    declarative => {
        file => "",
        type => "",
        value => ""
    }
});

done_testing;

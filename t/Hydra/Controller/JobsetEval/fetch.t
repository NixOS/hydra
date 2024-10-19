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

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});
ok(evalSucceeds($jobset), "Evaluating jobs/basic.nix should exit with return code 0");

my ($eval, @evals) = $jobset->jobsetevals;

subtest "Fetching the eval's overview" => sub {
    my $fetch = request(GET '/eval/' . $eval->id);
    is($fetch->code, 200, "eval page is 200");
};

subtest "Fetching the eval's overview" => sub {
    my $fetch = request(GET '/eval/' . $eval->id . '/channel');
    use Data::Dumper;
    print STDERR Dumper $fetch->content;
    is($fetch->code, 200, "channel page is 200");
};

subtest "Fetching the eval's overview" => sub {
    my $fetch = request(GET '/eval/' . $eval->id, '/errors');
    is($fetch->code, 200, "errors page is 200");
};


done_testing;

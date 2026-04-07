use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json encode_json);

my %ctx = test_init();

use HTTP::Request::Common;

use Test2::V0;
setup_catalyst_test($ctx{context});

require Hydra::Schema;
require Hydra::Helper::Nix;

my $db = $ctx{context}->db();

request(GET '/');
my $metrics = request(GET '/metrics');
ok($metrics->is_success);

like(
    $metrics->content,
    qr/http_requests_total\{action="index",code="200",controller="Hydra::Controller::Root",method="GET"\} 1/,
    "Metrics are collected"
);

done_testing;

use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;

use Test2::V0;

my $db = $ctx{context}->db();

my ($res, $stdout, $stderr) = $ctx{context}->capture_cmd(60, ("hydra-send-stats", "--once"));
is($stdout, "", "hydra-send-stats stdout should be empty");
is($stderr, "", "hydra-send-stats stderr should be empty");
is($res, 0, "hydra-send-stats --once should exit zero");

done_testing;

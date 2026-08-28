use strict;
use warnings;
use Setup;
use Hydra::Config;
use Test2::V0;

my %ctx = test_init(
    use_external_destination_store => 0,
    hydra_config                   => "include foo.conf"
);

write_file($ctx{'tmpdir'} . "/foo.conf", q|
<foo>
  include bar.conf
</foo>
|);

write_file($ctx{'tmpdir'} . "/bar.conf", q|
  bar = baz
|);

is(do {
    local $ENV{HYDRA_CONFIG} = $ctx{context}->{central}{hydra_config_file};
    getHydraConfig()
}, {
    # Everything the harness writes into every test's hydra.conf, since this
    # asserts the config exactly. The evaluation settings are there because
    # evaluation now runs as a build, which needs telling where to build.
    queue_runner_metrics_address => "127.0.0.1:0",
    evaluation_build_system_features => "",
    evaluation_build_store_uri => match(qr{^unix://}),
    foo => { bar => "baz" }
}, "Nested includes work.");

done_testing;

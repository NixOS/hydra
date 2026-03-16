use strict;
use warnings;
use Setup;
use Hydra::Config;

my %ctx = test_init(hydra_config => q|
<statsd>
  host = foo.bar
  port = 18125
</statsd>
|);

require Hydra::Helper::Nix;
use Test2::V0;

is(Hydra::Helper::Nix::getStatsdConfig(getHydraConfig()), {
    'host' => "foo.bar",
    'port' => 18125
}, "Reading specific configuration from the hydra.conf works");

is(Hydra::Helper::Nix::getStatsdConfig(), {
    'host' => "localhost",
    'port' => 8125
}, "A totally empty configuration yields default options");

is(Hydra::Helper::Nix::getStatsdConfig({
    "statsd" => {

    }
}), {
    'host' => "localhost",
    'port' => 8125
}, "A empty statsd block yields default options");

is(Hydra::Helper::Nix::getStatsdConfig({
    "statsd" => {
        'host' => "statsdhost"
    }
}), {
    'host' => "statsdhost",
    'port' => 8125
}, "An overridden statsd host propogates, but the other defaults are returned");

is(Hydra::Helper::Nix::getStatsdConfig({
    "statsd" => {
        'port' => 5218
    }
}), {
    'host' => "localhost",
    'port' => 5218
}, "An overridden statsd port propogates, but the other defaults are returned");

is(Hydra::Helper::Nix::getStatsdConfig({
    "statsd" => {
        'host' => 'my.statsd.host',
        'port' => 5218
    }
}), {
    'host' => "my.statsd.host",
    'port' => 5218
}, "An overridden statsd port and host propogate");

done_testing;

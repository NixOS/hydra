use strict;
use Setup;

my %ctx = test_init(hydra_config => q|
<hydra_notify>
  <prometheus>
    listen_address = 127.0.0.1
    port = 9199
  </prometheus>
</hydra_notify>
|);

require Hydra::Helper::Nix;
use Test2::V0;

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig(Hydra::Helper::Nix::getHydraConfig()), {
    'listen_address' => "127.0.0.1",
    'port' => 9199
}, "Reading specific configuration from the hydra.conf works");


is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => ":)"
}), undef, "Invalid (hydra_notify is a string) configuration options are undef");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => []
}), undef, "Invalid (hydra_notify is a list) configuration options are undef");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => {}
}), undef, "Invalid (hydra_notify is an empty hash) configuration options are undef");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => {
        "prometheus" => ":)"
    }
}), undef, "Invalid (hydra_notify.prometheus is a string) configuration options are undef");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => {
        "prometheus" => {}
    }
}), undef, "Invalid (hydra_notify.prometheus is an empty hash) configuration options are undef");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => {
        "prometheus" => {
            "listen_address" => "0.0.0.0"
        }
    }
}), undef, "Invalid (hydra_notify.prometheus.port is missing) configuration options are undef");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => {
        "prometheus" => {
            "port" => 1234
        }
    }
}), undef, "Invalid (hydra_notify.prometheus.listen_address is missing) configuration options are undef");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => {
        "prometheus" => {
            "listen_address" => "127.0.0.1",
            "port" => 1234
        }
    }
}), {
    "listen_address" => "127.0.0.1",
    "port" => 1234
}, "Fully specified hydra_notify.prometheus config is valid and returned");

is(Hydra::Helper::Nix::getHydraNotifyPrometheusConfig({
    "hydra_notify" => {
        "prometheus" => {
            "listen_address" => "127.0.0.1",
            "port" => 1234,
            "extra_keys" => "meh",
        }
    }
}), {
    "listen_address" => "127.0.0.1",
    "port" => 1234
}, "extra configuration in hydra_notify.prometheus is not returned");

done_testing;

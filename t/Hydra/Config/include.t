use strict;
use warnings;
use Setup;
use Hydra::Config;
use Test2::V0;

my %ctx = test_init(
    use_external_destination_store => 0,
    hydra_config                   => "include foo.conf"
);

write_file(
    $ctx{'tmpdir'} . "/foo.conf", q|
<foo>
  include bar.conf
</foo>
|
);

write_file(
    $ctx{'tmpdir'} . "/bar.conf", q|
  bar = baz
|
);

is(
    getHydraConfig(),
    {
        foo => { bar => "baz" }
    },
    "Nested includes work."
);

done_testing;

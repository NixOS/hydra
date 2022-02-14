use strict;
use warnings;
use Setup;
use Data::Dumper;
use Test2::V0;
use Hydra::Helper::Escape;

subtest "checking individual attribute set elements" => sub {
    my %values = (
        ""         => '""',
        "."        => '"."',
        "foobar"   => '"foobar"',
        "foo.bar"  => '"foo.bar"',
        "🌮"        => '"🌮"',
        'foo"bar'  => '"foo\"bar"',
        'foo\\bar' => '"foo\\\\bar"',
        '$bar'     => '"\\$bar"',
    );

    for my $input (keys %values) {
        my $value = $values{$input};
        is(escapeString($input), $value, "Escaping the value: " . $input);
    }
};

subtest "escaping path components of a nested attribute" => sub {
    my %values = (
        ""         => '""',
        "."        => '"".""',
        "...."     => '""."".""."".""',
        "foobar"   => '"foobar"',
        "foo.bar"  => '"foo"."bar"',
        "🌮"        => '"🌮"',
        'foo"bar'  => '"foo\"bar"',
        'foo\\bar' => '"foo\\\\bar"',
        '$bar'     => '"\\$bar"',
    );

    for my $input (keys %values) {
        my $value = $values{$input};
        is(escapeAttributePath($input), $value, "Escaping the attribute path: " . $input);
    }
};

done_testing;

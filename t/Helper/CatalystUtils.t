use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::CatalystUtils;

subtest "trim" => sub {
    my %values = (
        "" => "",
        "🌮" => '🌮',
        " 🌮" => '🌮',
        "🌮 " => '🌮',
        " 🌮 " => '🌮',
        "\n🌮 " => '🌮',
        "\n\t🌮\n\n\t" => '🌮',
    );

    for my $input (keys %values) {
        my $value = $values{$input};
        is(trim($input), $value, "Trim the value: " . $input);
    }

    my $uninitialized;

    is(trim($uninitialized), '', "Trimming an uninitialized value");
};

done_testing;

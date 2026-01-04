use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::CatalystUtils;

my $ctx = test_context();

my $builds = $ctx->makeAndEvaluateJobset(
    expression => "basic.nix",
    build => 1
);

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

subtest "showJobName" => sub {
    ok(showJobName($builds->{"empty_dir"}), "showJobName succeeds");
};

done_testing;

use strict;
use warnings;
use Hydra::Config;
use Test2::V0;

# Hydra's two kinds of mail are configured separately, in an
# `email_notifications` block. The deprecated singular `email_notification`
# used to turn on both and has to keep doing so, but the two cannot be
# combined.

subtest "nothing set" => sub {
    my $config = {};
    is(buildEmailNotificationEnabled($config), F(), "no build mail");
    is(evalEmailNotificationEnabled($config), F(), "no evaluation mail");
};

subtest "the deprecated key enables both" => sub {
    my $config = { email_notification => 1 };
    is(buildEmailNotificationEnabled($config), T(), "build mail");
    is(evalEmailNotificationEnabled($config), T(), "evaluation mail");
};

subtest "the block's settings are independent" => sub {
    my $build_only = { email_notifications => { build => 1 } };
    is(buildEmailNotificationEnabled($build_only), T(), "build on");
    is(evalEmailNotificationEnabled($build_only), F(),
        "turning on build mail does not turn on evaluation mail");

    my $eval_only = { email_notifications => { eval => 1 } };
    is(evalEmailNotificationEnabled($eval_only), T(), "eval on");
    is(buildEmailNotificationEnabled($eval_only), F(),
        "turning on evaluation mail does not turn on build mail");
};

subtest "setting both the block and the deprecated key is an error" => sub {
    my $config = {
        email_notification => 1,
        email_notifications => { eval => 0 },
    };
    like(
        dies { buildEmailNotificationEnabled($config) },
        qr/sets both/,
        "says the two ways of spelling it cannot be combined"
    );
};

subtest "only 1 enables" => sub {
    is(buildEmailNotificationEnabled({ email_notifications => { build => 0 } }), F(), "0 is off");
    is(buildEmailNotificationEnabled({ email_notifications => { build => "" } }), F(), "empty is off");
};

subtest "the plural written as a scalar is a mistake worth naming" => sub {
    like(
        dies { buildEmailNotificationEnabled({ email_notifications => 1 }) },
        qr/is a block/,
        "says it is a block, and points at the singular spelling"
    );
};

done_testing;

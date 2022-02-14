use strict;
use warnings;
use Setup;
use Data::Dumper;
use Test2::V0;
use Hydra::Helper::AttributeSet;

subtest "splitting an attribute path in to its component parts" => sub {
    my %values = (
        ""        => [''],
        "."       => [ '', '' ],
        "...."    => [ '', '', '', '', '' ],
        "foobar"  => ['foobar'],
        "foo.bar" => [ 'foo', 'bar' ],
        "🌮"       => ['🌮'],

        # not supported: 'foo."bar.baz".tux' => [ 'foo', 'bar.baz', 'tux' ]
        # the edge cases are fairly significant around escaping and unescaping.
    );

    for my $input (keys %values) {
        my @value      = @{ $values{$input} };
        my @components = Hydra::Helper::AttributeSet::splitPath($input);
        is(\@components, \@value, "Splitting the attribute path: " . $input);
    }
};

my $attrs = Hydra::Helper::AttributeSet->new();
$attrs->registerValue("foo");
$attrs->registerValue("bar.baz.tux");
$attrs->registerValue("bar.baz.bux.foo.bar.baz");

my @enumerated = $attrs->enumerate();
is(
    \@enumerated,
    [
        # "foo": skipped since we're registering values, and we
        # only want to track nested attribute sets.

        # "bar.baz.tux": expand the path
        "bar",
        "bar.baz",

        #"bar.baz.bux.foo.bar.baz": expand the path, but only register new
        # attribute set names.
        "bar.baz.bux",
        "bar.baz.bux.foo",
        "bar.baz.bux.foo.bar",
    ],
    "Attribute set paths are registered."
);

done_testing;

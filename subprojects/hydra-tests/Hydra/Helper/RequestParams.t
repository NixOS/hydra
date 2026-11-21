use utf8;
use strict;
use warnings;
use Test2::V0;
use JSON::MaybeXS ();
use Types::Standard qw(Str HashRef Dict Optional Slurpy);
use Hydra::Helper::RequestParams qw(
    requestParams Flag MaybeFlag Strings Integer
    matching oneOf positiveInteger record mapOf externalLink
);

# Just enough of a Catalyst context for `requestParams`.
package FakeContext {
    sub new {
        my ($class, %args) = @_;
        return bless { warnings => [], %args }, $class;
    }
    sub log { return $_[0] }
    sub warn { push @{$_[0]{warnings}}, $_[1] }
    sub req { return $_[0] }
    sub request { return $_[0] }
    sub path { return "test" }
    sub data { return $_[0]{data} }
    sub params { return $_[0]{params} // {} }
}

# `badRequest` responds and detaches; here it just dies with the message.
{
    no warnings 'redefine';
    *Hydra::Helper::RequestParams::badRequest = sub { die "400: $_[1]\n" };
}

sub decode {
    my ($spec, $params, %opts) = @_;
    my $c = FakeContext->new(params => $params, %opts);
    my $result = requestParams($c, $spec);
    return ($result, $c->{warnings});
}

sub refused {
    my ($spec, $params) = @_;
    my $c = FakeContext->new(params => $params);
    return dies { requestParams($c, $spec) };
}

subtest "plain values" => sub {
    my ($p) = decode({ a => Str, b => Str, c => Str }, { a => "x", b => 3 });
    is($p, { a => "x", b => 3, c => undef }, "declared names, with missing ones undef");
};

subtest "only declared names can be read" => sub {
    my ($p) = decode({ system => Str }, { system => "x86_64-linux", sytem => "typo" });
    is($p->{system}, "x86_64-linux", "a declared name");
    like(dies { my $x = $p->{sytem} }, qr/disallowed key 'sytem'/, "a typo dies instead of being undef");
};

subtest "structure is refused where a value is expected" => sub {
    like(refused({ name => Str }, { name => { "!=" => "" } }), qr/parameter 'name'/, "an operator hash");
    like(refused({ name => Str }, { name => [ "a", "b" ] }), qr/parameter 'name'/, "a list, as from a repeated field");
    like(refused({ name => Str }, { name => \"literal" }), qr/parameter 'name'/, "a scalar reference");
    like(refused({ name => Str }, { name => JSON::MaybeXS::true }), qr/parameter 'name'/, "a JSON boolean");
};

subtest "Flag" => sub {
    my ($p) = decode(
        { map { $_ => Flag } qw(on empty zero one jtrue jfalse absent) },
        { on => "on", empty => "", zero => "0", one => "1",
          jtrue => JSON::MaybeXS::true, jfalse => JSON::MaybeXS::false },
    );
    is($p, { on => 1, empty => 0, zero => 0, one => 1, jtrue => 1, jfalse => 0, absent => 0 },
        "checkboxes, JSON booleans and absence, as 1 or 0");
    like(refused({ f => Flag }, { f => {} }), qr/parameter 'f'/, "but not a hash");

    my ($q, $warnings) = decode({ map { $_ => Flag } qw(on one jtrue) }, { on => "on", one => "1", jtrue => JSON::MaybeXS::true });
    is($warnings, [], "the canonical spellings, without warnings");
    ($q, $warnings) = decode({ f => Flag }, { f => "false" });
    is($q->{f}, 1, "\"false\" still means on");
    like($warnings->[0], qr/Deprecated: ‘false’ for the flag 'f'.*read as on/, "but is deprecated");

    ($q) = decode({ map { $_ => MaybeFlag } qw(on off absent) }, { on => "on", off => JSON::MaybeXS::false });
    is($q, { on => 1, off => 0, absent => undef }, "MaybeFlag keeps a missing one missing");
};

subtest "Strings" => sub {
    my ($p) = decode({ one => Strings, many => Strings, none => Strings }, { one => "a", many => [ "a", "b" ] });
    is($p, { one => [ "a" ], many => [ "a", "b" ], none => undef }, "one value is a one-element list");
    like(refused({ l => Strings }, { l => [ { x => 1 } ] }), qr/parameter 'l'/, "a hash inside the list");
};

subtest "nested records" => sub {
    my $inputs = HashRef[Dict[value => Optional[Str], flag => Optional[Flag], Slurpy[HashRef]]];
    my ($p) = decode({ inputs => $inputs },
        { inputs => { src => { value => "v", flag => JSON::MaybeXS::false, extra => [ 1 ] } } });
    is($p->{inputs}{src}{value}, "v", "a value inside");
    is($p->{inputs}{src}{flag}, 0, "a flag inside is coerced");
    like(refused({ inputs => $inputs }, { inputs => { src => { value => { "-x" => 1 } } } }),
        qr/parameter 'inputs'/, "structure inside is refused");
};

subtest "Integer" => sub {
    my ($p, $warnings) = decode({ map { $_ => Integer } qw(n spaced jtrue) }, { n => 3, spaced => " 4 ", jtrue => JSON::MaybeXS::true });
    is($p, { n => 3, spaced => 4, jtrue => 1 }, "numbers, padded strings and JSON booleans");
    is(scalar @$warnings, 1, "with a warning for the boolean");
    like($warnings->[0], qr/Deprecated.*'jtrue'/, "deprecating it");
    like(refused({ n => Integer }, { n => "x" }), qr/parameter 'n'/, "but not other strings");
};

subtest "matching" => sub {
    my $name = matching(qr/[a-z]+/, sub { "Bad name ‘$_’." });
    my ($p) = decode({ a => $name, b => $name, c => $name }, { a => " ab ", b => "" });
    is($p, { a => "ab", b => undef, c => undef }, "trimmed, with empty the same as missing");
    like(refused({ a => $name }, { a => "a b" }), qr/^400: Bad name ‘a b’\.$/, "refused with its own message");

    my $required = matching(qr/[a-z]+/, sub { "Bad name ‘$_’." }, required => 1);
    like(refused({ a => $required }, {}), qr/Bad name ‘’/, "a required one can't be missing");
};

subtest "oneOf and positiveInteger" => sub {
    my $state = oneOf([0, 1, 2], sub { "Bad state ‘$_’." });
    my $period = oneOf([qw(hour day)], "Bad period.");
    my ($p) = decode({ s => $state, t => $period }, { s => " 2 ", t => "day" });
    is($p, { s => 2, t => "day" }, "numbers and strings");
    like(refused({ s => $state }, { s => 3 }), qr/Bad state ‘3’/, "not another number");
    like(refused({ t => $period }, { t => "week" }), qr/Bad period/, "nor another string");
    like(refused({ n => positiveInteger("Must be positive.") }, { n => 0 }), qr/Must be positive/, "zero isn't positive");
};

subtest "record and mapOf" => sub {
    my $inputs = mapOf(
        matching(qr/[a-z]+/, sub { "Bad input name ‘$_’." }),
        record(required => { type => oneOf([qw(git)], sub { "Bad input type ‘$_’." }) }, optional => { flag => Flag }),
    );
    my ($p) = decode({ inputs => $inputs }, { inputs => { src => { type => "git", flag => "on", other => 1 } } });
    is($p->{inputs}{src}, { type => "git", flag => 1, other => 1 }, "fields coerced, others kept");
    like(refused({ inputs => $inputs }, { inputs => { "Bad" => { type => "git" } } }), qr/Bad input name ‘Bad’/, "a bad name");
    like(refused({ inputs => $inputs }, { inputs => { src => { type => "svn" } } }), qr/Bad input type ‘svn’/, "a bad field");
    like(refused({ inputs => $inputs }, { inputs => { src => {} } }), qr/Bad input type ‘’/, "a missing required field");
};

subtest "externalLink" => sub {
    my $link = externalLink("Must be http(s).");
    my ($p) = decode({ a => $link, b => $link }, { a => "https://Example.com/" });
    is($p->{a}->text, "https://example.com/", "parsed and canonical");
    is($p->{b}, undef, "missing");
    like(refused({ a => $link }, { a => "javascript:alert(1)" }), qr/Must be http/, "only http(s)");
};

subtest "defaults" => sub {
    my $name = matching(qr/[a-z]+/, sub { "Bad name ‘$_’." }, required => 1);
    my $c = FakeContext->new(params => {});
    is(requestParams($c, { name => $name }, defaults => { name => "fromurl" })->{name}, "fromurl", "fill in a missing value");
    like(dies { requestParams($c, { name => $name }, defaults => { name => "From URL" }) }, qr/Bad name ‘From URL’/,
        "and are checked like any other");
};

subtest "undeclared parameters" => sub {
    my ($p, $warnings) = decode({ a => Str }, { a => "x", zeta => 1, beta => 2 });
    is($p, { a => "x" }, "are left out");
    is(scalar @$warnings, 1, "with one warning");
    like($warnings->[0], qr/beta, zeta/, "naming them");

    my $c = FakeContext->new(params => { b => 1 });
    requestParams($c, { a => Str }, quiet => 1);
    is($c->{warnings}, [], "but not when quiet");

    $c = FakeContext->new(params => { a => "x", readonly => 1, typo => 1 });
    requestParams($c, { a => Str }, ignore => [ "readonly" ]);
    is(scalar @{$c->{warnings}}, 1, "nor about ignored ones");
    unlike($c->{warnings}[0], qr/readonly/, "which the warning leaves out");
};

subtest "source" => sub {
    my ($p) = decode({ a => Str }, { a => "query" }, data => { a => "body" });
    is($p->{a}, "body", "a JSON body takes the place of the query and form parameters");
    my $warnings;
    ($p, $warnings) = decode({ a => Str }, { a => "query" }, data => {});
    is($p->{a}, "query", "unless it is empty");
    like($warnings->[0], qr/Deprecated: an empty JSON body/, "which is deprecated");

    my $c = FakeContext->new(params => { a => "query" }, data => [ 1, 2 ]);
    like(dies { requestParams($c, { a => Str }) }, qr/JSON object/, "a body that isn't an object is refused");

    $c = FakeContext->new(params => { a => "query" }, data => { a => "body" });
    is(requestParams($c, { a => Str }, from => $c->params)->{a}, "query", "`from` picks another source");
};

done_testing;

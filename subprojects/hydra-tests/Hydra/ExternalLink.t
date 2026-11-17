use strict;
use warnings;
use Test2::V0;

use Hydra::ExternalLink;

subtest "http(s) URLs are accepted, in canonical form" => sub {
    my %expected = (
        "https://example.com/" => "https://example.com/",
        "http://example.com/" => "http://example.com/",
        "http://example.com" => "http://example.com/",
        "HTTPS://Example.COM:443/a b" => "https://example.com/a%20b",
        " https://example.com " => "https://example.com/",
        "https://example.com/\"><script>" => "https://example.com/%22%3E%3Cscript%3E",
    );
    for my $url (sort keys %expected) {
        my $link = Hydra::ExternalLink->parse($url);
        isa_ok($link, ['Hydra::ExternalLink::Accepted'], "'$url' is accepted");
        isa_ok($link->uri, ['URI'], "'$url' has a URI");
        is($link->uri->as_string, $expected{$url}, "'$url' is canonicalised");
        is($link->text, $expected{$url}, "'$url' displays canonically");
    }
};

subtest "anything else is rejected, but kept for display" => sub {
    for my $url (
        # Not http(s).
        "javascript:alert(1)",
        "JavaScript:alert(1)",
        "data:text/html,<script>alert(1)</script>",
        "example.com:8080/foo",
        # No scheme at all.
        "example.com/foo",
        "//example.com/foo",
        "/foo",
    ) {
        my $link = Hydra::ExternalLink->parse($url);
        isa_ok($link, ['Hydra::ExternalLink::Rejected'], "'$url' is rejected");
        is($link->uri, undef, "'$url' has nothing to link to");
        is($link->text, $url, "'$url' displays as given");
    }
    is(Hydra::ExternalLink->parse(" javascript:alert(1)")->text, "javascript:alert(1)", "surrounding whitespace is trimmed");
};

subtest "both kinds are external links" => sub {
    isa_ok(Hydra::ExternalLink->parse("https://example.com/"), ['Hydra::ExternalLink'], "accepted");
    isa_ok(Hydra::ExternalLink->parse("javascript:alert(1)"), ['Hydra::ExternalLink'], "rejected");
};

subtest "both kinds are references" => sub {
    # As with `Hydra::StorePath`: DBIx::Class only routes a value through a
    # column's deflator when it is a reference.
    ok(ref(Hydra::ExternalLink->parse("https://example.com/")), "accepted");
    ok(ref(Hydra::ExternalLink->parse("javascript:alert(1)")), "rejected");
};

subtest "an empty string is no link at all" => sub {
    is(Hydra::ExternalLink->parse(""), undef, "''");
    is(Hydra::ExternalLink->parse(" "), undef, "' '");
    is(Hydra::ExternalLink->parse(undef), undef, "undef");
};

done_testing;

use strict;
use warnings;
use Setup;
use Test2::V0;
use HTTP::Request::Common qw(GET POST PUT);
use JSON::MaybeXS qw(encode_json);

my $ctx = test_context();

setup_catalyst_test($ctx);

my $db = $ctx->db();

my $user = $db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

my $project = $db->resultset('Projects')->create({ name => "tests", displayname => "Tests", owner => "alice" });

my $req = request(POST '/login',
    Referer => 'http://localhost/',
    Content => {
        username => 'alice',
        password => 'foobar'
    }
);
is($req->code, 302, "Logging in gets a 302");
my $cookie = $req->header("set-cookie");

sub updateHomepage {
    my ($homepage) = @_;
    return request(PUT '/project/tests',
        Accept => 'application/json',
        Content_Type => 'application/json',
        Cookie => $cookie,
        Content => encode_json({
            enabled => JSON::MaybeXS::true,
            visible => JSON::MaybeXS::true,
            name => "tests",
            displayname => "Tests",
            homepage => $homepage,
        })
    );
}

subtest "A rejected homepage is shown, but not linked to" => sub {
    # Written directly, bypassing the parser.
    $project->update({ homepage => "javascript:alert(1)" });

    my $page = request(GET '/project/tests');
    ok($page->is_success, "The project page loads");
    like($page->content, qr{javascript:alert\(1\)}, "The homepage is shown");
    unlike($page->content, qr{href="javascript:}, "It is not linked to");
    like($page->content, qr{\(invalid link\)}, "It is flagged as invalid");
};

subtest "An accepted homepage is linked to" => sub {
    $project->update({ homepage => "https://example.com/" });

    my $page = request(GET '/project/tests');
    ok($page->is_success, "The project page loads");
    like($page->content, qr{href="https://example.com/"}, "It is linked to");
};

subtest "The edit form rejects a homepage that is not an http(s) URL" => sub {
    for my $bad ("javascript:alert(1)", "example.com") {
        is(updateHomepage($bad)->code, 400, "'$bad' is a bad request");
    }
};

subtest "The edit form stores a homepage in canonical form" => sub {
    ok(updateHomepage("HTTPS://Example.COM/a b")->is_success, "The update succeeds");
    $project->discard_changes;
    is($project->get_column('homepage'), "https://example.com/a%20b", "It is stored canonically");
};

subtest "The edit form clears an empty homepage" => sub {
    ok(updateHomepage("")->is_success, "The update succeeds");
    $project->discard_changes;
    is($project->homepage, undef, "There is no homepage");
};

done_testing;

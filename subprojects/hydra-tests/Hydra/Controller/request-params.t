use strict;
use warnings;
use Setup;
use Test2::V0;
use HTTP::Request::Common;
use JSON::MaybeXS qw(encode_json decode_json);
use Hydra::Helper::CatalystUtils;

my $ctx = test_context();
setup_catalyst_test($ctx);
my $db = $ctx->db;

my $bob = $db->resultset('Users')->create({ username => 'bob', fullname => 'bob', emailaddress => 'bob@example.org', password => '!' });
$bob->setPassword('bob-pw');
my $project = $db->resultset('Projects')->create({ name => 'p', displayname => 'P', owner => 'bob' });
$project->jobsets->create({ name => 'j', nixexprinput => 'src', nixexprpath => 'default.nix', emailoverride => '' });

my %project = (name => 'p', displayname => 'P', enabled => 1, visible => 1, homepage => '');
my %jobset = (name => 'j', type => 0, nixexprpath => 'default.nix', nixexprinput => 'src', enabled => 1, checkinterval => 0, inputs => {});

sub json_request {
    my ($method, $path, $body, $cookie) = @_;
    my $req = HTTP::Request->new($method => "http://localhost$path");
    $req->header('Content-Type' => 'application/json', Accept => 'application/json', Referer => 'http://localhost/');
    $req->header(Cookie => $cookie) if defined $cookie;
    $req->content(ref $body ? encode_json($body) : $body);
    return request($req);
}

sub error_of { my $res = shift; return eval { decode_json($res->content)->{error} } // '' }

my $signin = request(POST '/login', Referer => 'http://localhost/',
    Content => { username => 'bob', password => 'bob-pw' });
is($signin->code, 302, "the sign-in form works");
my $cookie = $signin->header('Set-Cookie');

my $object = { "-anything" => "x" };

subtest "the sign-in form refuses anything but strings" => sub {
    foreach my $field (qw(username password)) {
        my $res = json_request(POST => '/login', { username => 'bob', password => 'bob-pw', $field => $object });
        is($res->code, 400, "an object as the $field");
        like(error_of($res), qr/\Q$field\E/, "and the error names the $field");
    }
    is(json_request(POST => '/login', { username => ['bob'], password => 'bob-pw' })->code, 400,
        "a list as the user name");
    is(json_request(POST => '/login', { username => 'bob', password => 'bob-pw' })->code, 302,
        "a JSON sign-in with strings still works");
};

subtest "user settings refuse an object" => sub {
    my $res = json_request(PUT => '/user/bob', { fullname => $object }, $cookie);
    is($res->code, 400, "PUT with an object as the full name");
    like(error_of($res), qr/fullname/, "and the error names the field");
    is($db->resultset('Users')->find('bob')->fullname, 'bob', "nothing was written");

    is(json_request(POST => '/user/bob?x-tunneled-method=PUT', { fullname => $object }, $cookie)->code, 400,
        "the same through a tunnelled POST");
};

subtest "project and jobset edits refuse objects" => sub {
    is(json_request(PUT => '/project/p', { %project, description => $object }, $cookie)->code, 400, "an object as the project description");
    is(json_request(PUT => '/project/p', { %project, declarative => { file => $object } }, $cookie)->code, 400, "an object inside declarative");
    is(json_request(PUT => '/jobset/p/j', { %jobset, emailoverride => $object }, $cookie)->code, 400, "an object as the jobset's email override");
    is(json_request(PUT => '/jobset/p/j', { %jobset, inputs => { src => { type => 'string', value => $object } } }, $cookie)->code, 400,
        "an object as an input value");
    is($db->resultset('Jobsets')->find({ project => 'p', name => 'j' })->emailoverride, '', "nothing was written");
};

subtest "lists only where a form sends one" => sub {
    my $res = request(GET '/search?query=foo&limit=5&limit=6', Accept => 'application/json');
    is($res->code, 400, "a repeated query parameter");
    like(error_of($res), qr/limit/, "and the error names it");
    is(request(GET '/search?query=foo&limit=5', Accept => 'application/json')->code, 200,
        "while a single one still works");

    $res = json_request(PUT => '/user/bob', { fullname => ['x'] }, $cookie);
    is($res->code, 400, "a JSON list as the full name");
    like(error_of($res), qr/fullname/, "and the error names it");
    is(request(PUT '/user/bob', Cookie => $cookie, Accept => 'application/json',
        Content => [ fullname => 'a', fullname => 'b' ])->code, 400, "a repeated form field");
    is(json_request(PUT => '/project/p', { %project, declarative => { file => ['x'] } }, $cookie)->code, 400,
        "a list inside declarative");
    is(json_request(PUT => '/jobset/p/j', { %jobset, inputs => { src => { type => 'boolean', value => ['true'] } } }, $cookie)->code, 400,
        "a list as an input value");

    is(request(PUT '/user/bob', Cookie => $cookie, Accept => 'application/json',
        Content => [ fullname => 'bob', roles => 'admin', roles => 'restart-jobs' ])->code, 204,
        "role checkboxes still arrive as a list");
    is([ map { $_->role } $bob->userroles->all ], [], "and only an admin can change roles");
};

subtest "a JSON body does not hide the query string" => sub {
    my $res = json_request(POST => '/search?query=a&query=b', { x => 1 });
    is($res->code, 400, "a repeated query parameter next to a JSON body");
    like(error_of($res), qr/query/, "and the error names it");
    is(json_request(POST => '/api/latestbuilds?nr=5&project=a&project=b', { x => 1 })->code, 400, "a repeated project filter next to a JSON body");
    is(json_request(POST => '/search?query=a', { x => 1 })->code, 200, "while a single query parameter still works");
};

subtest "what GET returns can be sent back" => sub {
    foreach my $paths ([ '/project/p' ], [ '/jobset/p/j' ], [ '/current-user', '/user/bob' ]) {
        my ($from, $to) = (@$paths, @$paths);
        my $got = request(GET $from, Accept => 'application/json', Cookie => $cookie);
        is($got->code, 200, "GET $from");
        my $res = json_request(PUT => $to, decode_json($got->content), $cookie);
        ok($res->is_success, "and PUT it back to $to unchanged") or diag $res->content;
    }
    ok(exists decode_json(request(GET '/current-user', Accept => 'application/json', Cookie => $cookie)->content)->{userroles},
        "the user's roles are part of what was sent back");
    is(request(POST '/api/push?jobsets=p:j&jobsets=p:j', Referer => 'http://localhost/', Cookie => $cookie)->code, 400,
        "but such a list is still refused outside a JSON body");
};

subtest "false means off" => sub {
    my $false = JSON::MaybeXS::false;
    my $res = json_request(PUT => '/project/p', { %project, enabled => $false, visible => $false,
        enable_dynamic_run_command => $false }, $cookie);
    ok($res->is_success, "a project with every flag false is accepted") or diag $res->content;
    $project->discard_changes;
    is([ $project->enabled, $project->hidden ], [ 0, 1 ], "and is stored disabled and hidden");

    $res = json_request(PUT => '/jobset/p/j', { %jobset, visible => $false, enableemail => $false,
        enable_dynamic_run_command => $false,
        inputs => { src => { type => 'string', value => 'abc', emailresponsible => $false } },
    }, $cookie);
    ok($res->is_success, "a jobset with every flag false is accepted") or diag $res->content;
    my $jobset = $db->resultset('Jobsets')->find({ project => 'p', name => 'j' });
    is([ $jobset->hidden, $jobset->enableemail ], [ 1, 0 ], "and is stored hidden, without email");
    is($jobset->jobsetinputs->find({ name => 'src' })->emailresponsible, 0, "and so is its input");

    my $true = JSON::MaybeXS::true;
    json_request(PUT => '/project/p', { %project, enabled => $true, visible => $true }, $cookie);
    $project->discard_changes;
    is([ $project->enabled, $project->hidden ], [ 1, 0 ], "true means on");

    $res = json_request(PUT => '/jobset/p/j', { %jobset, visible => 'on', enableemail => 'on',
        inputs => { src => { type => 'string', value => 'abc', emailresponsible => 'on' } },
    }, $cookie);
    ok($res->is_success, "a jobset as the web form sends it") or diag $res->content;
    $jobset->discard_changes;
    is([ $jobset->hidden, $jobset->enableemail ], [ 0, 1 ], "a ticked checkbox means on");
    is($jobset->jobsetinputs->find({ name => 'src' })->emailresponsible, 1, "for the input too");
};

subtest "a JSON body must be an object" => sub {
    is(json_request(POST => '/login', '[1, 2]')->code, 400, "a list as the whole body");
    is(json_request(POST => '/login', '"bob"')->code, 400, "a string as the whole body");
};

subtest "the structured values the API documents still work" => sub {
    my $res = json_request(PUT => '/jobset/p/j', { %jobset,
        visible => JSON::MaybeXS::true, description => 'built nightly',
        inputs => { src => { type => 'string', value => 'abc', emailresponsible => JSON::MaybeXS::false } },
    }, $cookie);
    ok($res->is_success, "jobset with booleans and inputs is accepted") or diag $res->content;
    my $jobset = $db->resultset('Jobsets')->find({ project => 'p', name => 'j' });
    is($jobset->description, 'built nightly', "description stored");
    is($jobset->jobsetinputs->find({ name => 'src' })->jobsetinputalts->first->value, 'abc', "input stored");

    $res = json_request(PUT => '/project/p', { %project,
        enabled => JSON::MaybeXS::true, visible => JSON::MaybeXS::true,
        declarative => { file => '', type => '', value => '' },
    }, $cookie);
    ok($res->is_success, "project with booleans and declarative is accepted") or diag $res->content;
};

subtest "checkRequestParams" => sub {
    my %nested = (one => 1, two => 2);
    my %lists = (many => 1);
    my $check = sub { checkRequestParams($_[0], \%nested, \%lists) };
    my %params = (a => 'x', b => 3, c => undef, d => JSON::MaybeXS::true, many => [ 'x', JSON::MaybeXS::false ]);
    is($check->(\%params), undef, "strings, numbers, null, booleans, and a list where allowed");
    is(\%params, { a => 'x', b => 3, c => undef, d => 1, many => [ 'x', 0 ] }, "booleans become 1 and 0");
    ok(defined $check->({ a => [ 'x' ] }), "a list under any other name");
    ok(defined $check->({ a => { b => 'c' } }), "a hash under any other name");
    ok(defined $check->({ many => [ { b => 'c' } ] }), "a hash inside a list");
    ok(defined $check->({ many => [ [ 'b' ] ] }), "a list inside a list");
    ok(defined $check->({ a => \"literal" }), "a scalar reference");
    is($check->({ one => { x => 'y' }, two => { x => { y => 'z' } } }), undef, "hashes as deep as allowed");
    ok(defined $check->({ one => { x => { y => 'z' } } }), "but not deeper");
    ok(defined $check->({ two => { x => { y => [ 'z' ] } } }), "nor a list inside them");

    my %errors = map { ($check->({ zeta => {}, alpha => [], mid => {} }) => 1) } 1 .. 20;
    is(scalar keys %errors, 1, "with several bad parameters, the error names the same one every time");
    like((keys %errors)[0], qr/alpha/, "the first by name");
};

done_testing;

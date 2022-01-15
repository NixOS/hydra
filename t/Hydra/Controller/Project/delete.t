use strict;
use warnings;
use Setup;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request;
use HTTP::Request::Common qw(GET POST DELETE);
use JSON::MaybeXS qw(decode_json encode_json);

my $ctx = test_context();

Catalyst::Test->import('Hydra');

my $user = $ctx->db()->resultset('Users')->create({
    username => 'alice',
    emailaddress => 'root@invalid.org',
    password => '!'
});
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

# Login and save cookie for future requests
my $req = request(POST '/login',
    Referer => 'http://localhost/',
    Content => {
        username => 'alice',
        password => 'foobar'
    }
);
is($req->code, 302, "Logging in gets a 302");
my $cookie = $req->header("set-cookie");

subtest "Deleting a simple project" => sub {
    my $builds = $ctx->makeAndEvaluateJobset(
        expression => "basic.nix"
    );
    my $project = $builds->{"empty_dir"}->project;

    my $responseNoAuth = request(DELETE "/project/${\$project->name}");
    is($responseNoAuth->code, 403, "Deleting a project without auth returns a 403");

    my $responseAuthed = request(DELETE "/project/${\$project->name}",
        Cookie => $cookie,
        Accept => "application/json"
    );
    is($responseAuthed->code, 200, "Deleting a project with auth returns a 200");

    my $response = request(GET "/project/${\$project->name}");
    is($response->code, 404, "Then getting the project returns a 404");

    is(
        $ctx->db->resultset('Builds')->find({ id => $builds->{"empty_dir"}->id }),
        undef,
        "The build isn't in the database anymore"
    );
};

done_testing;
use strict;
use Setup;
use Test2::V0;
use HTTP::Request::Common;
use Crypt::Passphrase;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

require Catalyst::Test;
Catalyst::Test->import('Hydra');
my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $scratch = "$ctx{tmpdir}/scratch";
mkdir $scratch;

my $uri = "file://$scratch/git-repo";
my $jobset = createJobsetWithOneInput('gitea', 'git-input.nix', 'src', 'git', $uri, $ctx{jobsdir});

ok(request('/project/tests')->is_success, "Project 'tests' exists");
my $project = $db->resultset('Projects')->find({name => "tests"})->update({private => 1});
ok(
    !request('/project/tests')->is_success,
    "Project 'tests' is private now and should be unreachable"
);

my $authenticator = Crypt::Passphrase->new(
    encoder    => 'Argon2',
    validators => [
        (sub {
            my ($password, $hash) = @_;

            return String::Compare::ConstantTime::equals($hash, sha1_hex($password));
        })
    ],
);
$db->resultset('Users')->create({
    username => "testing",
    emailaddress => 'testing@invalid.org',
    password => $authenticator->hash_password('foobar')
});

my $auth = request(
    POST(
        '/login',
        {username => 'testing', 'password' => 'foobar'},
        Origin => 'http://localhost', Accept => 'application/json'
    ),
    {host => 'localhost'}
);

ok(
    $auth->is_success,
    "Successfully logged in"
);

my $cookie = (split /;/, $auth->header('set_cookie'))[0];

ok(
    request(GET(
        '/project/tests',
        Cookie => $cookie
    ))->is_success,
    "Project visible for authenticated user."
);

updateRepository('gitea', "$ctx{testdir}/jobs/git-update.sh", $scratch);

ok(evalSucceeds($jobset), "Evaluating nix expression");
is(nrQueuedBuildsForJobset($jobset), 1, "Evaluating jobs/runcommand.nix should result in 1 build1");

ok(
    request('/eval/1')->code == 404,
    'Eval of private project not available for unauthenticated user.'
);

ok(
    request(GET '/eval/1', Cookie => $cookie)->is_success,
    'Eval available for authenticated User'
);

ok(
    request(GET '/jobset/tests/gitea', Cookie => $cookie)->is_success,
    'Jobset available for user'
);

ok(
    request(GET '/jobset/tests/gitea')->code == 404,
    'Jobset unavailable for guest'
);

ok(
    request('/build/1')->code == 404,
    'Build of private project not available for unauthenticated user.'
);

ok(
    request(GET '/build/1', Cookie => $cookie)->is_success,
    'Build available for authenticated User'
);

(my $build) = queuedBuildsForJobset($jobset);
ok(runBuild($build), "Build should succeed with exit code 0");

ok(
    request(GET '/jobset/tests/gitea/channel/latest', Cookie => $cookie)->is_success,
    'Channel available for authenticated user'
);

ok(
    request(GET '/jobset/tests/gitea/channel/latest')->code == 404,
    'Channel unavailable for guest'
);

done_testing;

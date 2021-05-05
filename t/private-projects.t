use strict;
use Setup;
use Test2::V0;
use HTTP::Request::Common;
use HTML::TreeBuilder::XPath;
use JSON;

my %ctx = test_init(
    use_external_destination_store => 0
);

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

my $user = $db->resultset('Users')->create({
    username => "testing",
    emailaddress => 'testing@invalid.org',
    password => ''
});
$user->setPassword('foobar');

my $auth = request(
    POST(
        '/login',
        {username => 'testing', 'password' => 'foobar'},
        Origin => 'http://localhost', Accept => 'application/json'
    ),
    {host => 'localhost'}
);

ok(
    $auth->code == 302,
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

updateRepository('gitea', "$ctx{testdir}/jobs/git-update.sh", $scratch);
ok(evalSucceeds($jobset), "Evaluating nix expression");

my @latest = split /\n/, `cd $scratch/git-repo && git log --oneline | head -2 | awk '{ print \$1 }'`;
my $rev1 = $latest[0];
my $rev2 = $latest[1];

my $scmdiff = "/api/scmdiff?type=git&rev1=$rev1&rev2=$rev2&branch=&uri=$uri";
my $auth_scmdiff = request(GET $scmdiff, Cookie => $cookie);

my $expected = <<DIFF;
diff --git a/bar b/bar
deleted file mode 100644
index 573541a..0000000
--- a/bar
+++ /dev/null
@@ -1 +0,0 @@
-0
DIFF

ok($auth_scmdiff->content eq $expected, 'Correct diff shown');

ok(
    $auth_scmdiff->is_success,
    'SCM diff works fine'
);

ok(
    request($scmdiff)->code == 500,
    'Unauthenticated SCM diff for priate project doesn\'t work'
);

my $latest_builds_unauth = request(GET "/all");

my $tree = HTML::TreeBuilder::XPath->new;
$tree->parse($latest_builds_unauth->content);
ok(!$tree->exists('/html//tbody/tr'), "No builds available");

my $latest_builds = request(GET "/all", Cookie => $cookie);

$tree = HTML::TreeBuilder::XPath->new;
$tree->parse($latest_builds->content);
ok($tree->exists('/html//tbody/tr'), "Builds available");

my $p2 = $db->resultset("Projects")->create({name => "public", displayname => "public", owner => "root"});
my $jobset2 = $p2->jobsets->create({
    name => "public", nixexprpath => 'basic.nix', nixexprinput => "jobs", emailoverride => ""
});

my $jobsetinput = $jobset2->jobsetinputs->create({name => "jobs", type => "path"});
$jobsetinput->jobsetinputalts->create({altnr => 0, value => $ctx{jobsdir}});

updateRepository('gitea', "$ctx{testdir}/jobs/git-update.sh", $scratch);
ok(evalSucceeds($jobset2), "Evaluating nix expression");
is(
    nrQueuedBuildsForJobset($jobset2),
    3,
    "Evaluating jobs/runcommand.nix should result in 3 builds"
);

(my $b1, my $b2, my $b3) = queuedBuildsForJobset($jobset2);
ok(runBuild($b1), "Build should succeed with exit code 0");
ok(runBuild($b2), "Build should succeed with exit code 0");
ok(runBuild($b3), "Build should succeed with exit code 0");
my $latest_builds_unauth2 = request(GET "/all");

$tree = HTML::TreeBuilder::XPath->new;
$tree->parse($latest_builds_unauth2->content);
is(
    scalar $tree->findvalues('/html//tbody/tr'),
    3,
    "Three builds available"
);

my $latest_builds2 = request(GET "/all", Cookie => $cookie);

$tree = HTML::TreeBuilder::XPath->new;
$tree->parse($latest_builds2->content);
is(
    scalar $tree->findvalues('/html//tbody/tr'),
    4,
    "Three builds available"
);

done_testing;

use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();

require Hydra; # calls setup()
require Hydra::View::TT;
require Catalyst::Test;

my $db = $ctx->db;


# The following lines are a cheap and hacky trick to get $c,
# there is no other reason to call /.
Catalyst::Test->import('Hydra');
my ($_request, $c) = ctx_request('/');


my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset = createBaseJobset("example", "bogus.nix", $ctx->jobsdir);
my $job = "myjob";


is(
    Hydra::View::TT::linkToProject(undef, $c, $project),
    '<a href="http://localhost/project/tests">tests</a>',
    "linkToProject"
);
is(
    Hydra::View::TT::linkToJobset(undef, $c, $jobset),
    '<a href="http://localhost/project/tests">tests</a>'
    . ':<a href="http://localhost/jobset/tests/example">example</a>',
    "linkToJobset"
);
is(
    Hydra::View::TT::linkToJob(undef, $c, $jobset, $job),
    '<a href="http://localhost/project/tests">tests</a>'
    . ':<a href="http://localhost/jobset/tests/example">example</a>'
    . ':<a href="http://localhost/job/tests/example/myjob">myjob</a>',
    "linkToJob"
);

is(
    Hydra::View::TT::makeNameLinksForJobset(undef, $c, $jobset),
    '<a href="http://localhost/project/tests">tests</a>'
    . ':example',
    "makeNameLinksForJobset"
);
is(
    Hydra::View::TT::makeNameLinksForJob(undef, $c, $jobset, $job),
    '<a href="http://localhost/project/tests">tests</a>'
    . ':<a href="http://localhost/jobset/tests/example">example</a>'
    . ':myjob',
    "makeNameLinksForJob"
);

is(
    Hydra::View::TT::makeNameTextForJobset(undef, $c, $jobset),
    'tests:example',
    "makeNameTextForJobset"
);
is(
    Hydra::View::TT::makeNameTextForJob(undef, $c, $jobset, $job),
    'tests:example:myjob',
    "makeNameTextForJob"
);

done_testing;

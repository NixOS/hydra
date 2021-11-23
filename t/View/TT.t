use feature 'unicode_strings';
use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

require Hydra; # calls setup()


my $db = Hydra::Model::DB->new;
hydra_setup($db);

require Hydra::View::TT;

# The following lines are a cheap and hacky trick to get $c,
# there is no other reason to call /.
require Catalyst::Test;
Catalyst::Test->import('Hydra');
my($_, $c) = ctx_request('/');


my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset = createBaseJobset("example", "bogus.nix", $ctx{jobsdir});
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

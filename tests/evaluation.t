use strict;
use Cwd;
use Setup;

(my $datadir, my $pgsql) = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test::Simple tests => 68;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $res;
my $stdout;
my $stderr;

my $jobsBaseUri = "file://".getcwd;
my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});
my $jobset;


# Test jobset with 2 jobs, one has parameter of succeeded build of the other
$jobset = createJobsetWithOneInput("build-output-as-input", "build-output-as-input.nix", "build1", "build", "build1");

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-output-as-input.nix should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 1 , "Evaluating jobs/build-output-as-input.nix for first time should result in 1 build in queue");
for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    ok($newbuild->finished == 1 && $newbuild->buildstatus == 0, "Build '".$build->job."' from jobs/basic.nix should have buildstatus 0");
}

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-output-as-input.nix for second time should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 1 , "Evaluating jobs/build-output-as-input.nix for second time after building build1 should result in 1 build in queue");
for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    ok($newbuild->finished == 1 && $newbuild->buildstatus == 0, "Build '".$build->job."' from jobs/basic.nix should have buildstatus 0");
}


# Test scm inputs
my @scminputs = (
    {
        name => "svn",
        nixexpr => "svn-input.nix",
        type => "svn",
        uri => "$jobsBaseUri/svn-repo",
        update => getcwd . "/jobs/svn-update.sh"
    },
    {
        name => "svn-checkout",
        nixexpr => "svn-checkout-input.nix",
        type => "svn-checkout",
        uri => "$jobsBaseUri/svn-checkout-repo",
        update => getcwd . "/jobs/svn-checkout-update.sh"
    },
    {
        name => "git",
        nixexpr => "git-input.nix",
        type => "git",
        uri => "$jobsBaseUri/git-repo",
        update => getcwd . "/jobs/git-update.sh"
    },
    {
        name => "git-rev",
        nixexpr => "git-rev-input.nix",
        type => "git",
        uri => "$jobsBaseUri/git-repo 7f60df502b96fd54bbfa64dd94b56d936a407701",
        update => getcwd . "/jobs/git-rev-update.sh"
    },
    {
        name => "deepgit",
        nixexpr => "deepgit-input.nix",
        type => "git",
        uri => "$jobsBaseUri/git-repo master 1",
        update => getcwd . "/jobs/git-update.sh"
    },
    {
        name => "bzr",
        nixexpr => "bzr-input.nix",
        type => "bzr",
        uri => "$jobsBaseUri/bzr-repo",
        update => getcwd . "/jobs/bzr-update.sh"
    },
    {
        name => "bzr-checkout",
        nixexpr => "bzr-checkout-input.nix",
        type => "bzr-checkout",
        uri => "$jobsBaseUri/bzr-checkout-repo",
        update => getcwd . "/jobs/bzr-checkout-update.sh"
    },
    {
        name => "hg",
        nixexpr => "hg-input.nix",
        type => "hg",
        uri => "$jobsBaseUri/hg-repo",
        update => getcwd . "/jobs/hg-update.sh"
    },
    {
        name => "darcs",
        nixexpr => "darcs-input.nix",
        type => "darcs",
        uri => "$jobsBaseUri/darcs-repo",
        update => getcwd . "/jobs/darcs-update.sh"
    }
);

foreach my $scm ( @scminputs ) {
    my $scmName = $scm->{"name"};
    my $nixexpr = $scm->{"nixexpr"};
    my $type = $scm->{"type"};
    my $uri = $scm->{"uri"};
    my $update = $scm->{"update"};
    $jobset = createJobsetWithOneInput($scmName, $nixexpr, "src", $type, $uri);

    my $state = 0;
    my $q = 0;
    my ($loop, $updated) = updateRepository($scmName, $update);
    while($loop) {
        my $c = 0;

        # Verify that it can be fetched and possibly queued.
        ok(evalSucceeds($jobset),                  "$scmName:$state.$c: Evaluating nix-expression."); $c++;

        # Verify that the evaluation has queued a new job and evaluate again to ...
        if ($updated) {
            $q++;
            ok(nrQueuedBuildsForJobset($jobset) == $q, "$scmName:$state.$c: Expect $q jobs in the queue."); $c++;
            ok(evalSucceeds($jobset),                  "$scmName:$state.$c: Evaluating nix-expression again."); $c++;
        }

        # ... check that it is deterministic and not queued again.
        ok(nrQueuedBuildsForJobset($jobset) == $q, "$scmName:$state.$c: Expect $q jobs in the queue."); $c++;

        $state++;
        ($loop, $updated) = updateRepository($scmName, $update, getcwd . "/$scmName-repo/");
    }
}

# Test build products

$jobset = createBaseJobset("build-products", "build-products.nix");

ok(evalSucceeds($jobset),                  "Evaluating jobs/build-products.nix should exit with return code 0");
ok(nrQueuedBuildsForJobset($jobset) == 2 , "Evaluating jobs/build-products.nix should result in 2 builds");

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/build-products.nix should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    ok($newbuild->finished == 1 && $newbuild->buildstatus == 0, "Build '".$build->job."' from jobs/build-products.nix should have buildstatus 0");

    my $buildproducts = $db->resultset('BuildProducts')->search({ build => $build->id });
    my $buildproduct = $buildproducts->next;

    if($build->job eq "simple") {
        ok($buildproduct->name eq "text.txt", "We should have text.txt, but found: ".$buildproduct->name."\n");
    } elsif ($build->job eq "with_spaces") {
        ok($buildproduct->name eq "some text.txt", "We should have: \"some text.txt\", but found: ".$buildproduct->name."\n");
    }
}

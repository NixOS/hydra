use strict;
use Cwd;
use Setup;

(my $datadir, my $pgsql) = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $jobsBaseUri = "file://".getcwd;

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

    subtest "With the SCM input named $scmName" => sub {
        my $nixexpr = $scm->{"nixexpr"};
        my $type = $scm->{"type"};
        my $uri = $scm->{"uri"};
        my $update = $scm->{"update"};
        my $jobset = createJobsetWithOneInput($scmName, $nixexpr, "src", $type, $uri);

        my $state = 0;
        my $q = 0;
        my ($loop, $updated) = updateRepository($scmName, $update);
        while($loop) {
            subtest "Mutation number $state" => sub {
                # Verify that it can be fetched and possibly queued.
                ok(evalSucceeds($jobset),                  "Evaluating nix-expression.");

                # Verify that the evaluation has queued a new job and evaluate again to ...
                if ($updated) {
                    $q++;
                    is(nrQueuedBuildsForJobset($jobset), $q, "Expect $q jobs in the queue.");
                    ok(evalSucceeds($jobset),                "Evaluating nix-expression again.");
                }

                # ... check that it is deterministic and not queued again.
                is(nrQueuedBuildsForJobset($jobset), $q, "Expect deterministic evaluation.");

                $state++;
                ($loop, $updated) = updateRepository($scmName, $update, getcwd . "/$scmName-repo/");
            };
        }
    };
}

done_testing;

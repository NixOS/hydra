use feature 'unicode_strings';
use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json);

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');
use HTTP::Request::Common qw(GET);

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});
ok(evalSucceeds($jobset), "Evaluating jobs/basic.nix should exit with return code 0");

my ($eval, @rest) = $jobset->jobsetevals;
ok($eval, "jobset has an eval");

subtest "Without compare param, JSON has no diff field" => sub {
    # Regression guard: the controller auto-resolves eval2 to the previous
    # eval when compare is absent, so gating on eval2 would leak the diff.
    # We gate on the explicit compare param instead.
    my $resp = request(GET '/eval/' . $eval->id,
        Accept => 'application/json');
    is($resp->code, 200, "eval JSON is 200");

    my $data = decode_json($resp->content);
    ok(!exists $data->{diff}, "no diff field without compare param");
    ok(exists $data->{id}, "has id field");
    ok(exists $data->{builds}, "has builds field");
};

subtest "With compare param, JSON includes diff field" => sub {
    # Self-compare: every build lands in unfinished (finished==0) or
    # stillSucceed/stillFail (finished==1). The point is to verify the
    # diff structure and per-build shape, not to exercise every category.
    my $resp = request(GET '/eval/' . $eval->id . '?compare=' . $eval->id,
        Accept => 'application/json');
    is($resp->code, 200, "eval compare JSON is 200");

    my $data = decode_json($resp->content);
    ok(exists $data->{diff}, "has diff field with compare");

    my $diff = $data->{diff};
    for my $key (qw(stillSucceed stillFail nowSucceed nowFail new aborted unfinished removed
                    totalAborted totalFailed totalQueued)) {
        ok(exists $diff->{$key}, "diff has $key");
    }

    # Each build (except in `removed`, which has a reduced shape) carries
    # only {id, job}. buildstatus/finished/system are implied by category:
    # stillFail entries are always finished builds with non-zero status, etc.
    for my $category (qw(stillSucceed stillFail nowSucceed nowFail new aborted unfinished)) {
        for my $build (@{$diff->{$category}}) {
            ok(exists $build->{id}, "build in $category has id");
            ok(exists $build->{job}, "build in $category has job");
            ok(!exists $build->{buildstatus}, "build in $category has no buildstatus (implied by category)");
            ok(!exists $build->{finished}, "build in $category has no finished (implied by category)");
        }
    }

    # removed entries only have {job, system} — those jobs don't exist
    # in the current eval, so no id/buildstatus.
    for my $entry (@{$diff->{removed}}) {
        ok(exists $entry->{job}, "removed entry has job");
        ok(exists $entry->{system}, "removed entry has system");
    }
};

done_testing;

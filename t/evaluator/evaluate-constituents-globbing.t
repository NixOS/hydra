use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::Exec;
use Data::Dumper;

my $ctx = test_context();

subtest "general glob testing" => sub {
    my $jobsetCtx = $ctx->makeJobset(
        expression => 'constituents-glob.nix',
    );
    my $jobset = $jobsetCtx->{"jobset"};

    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        ("hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name)
    );
    is($res, 0, "hydra-eval-jobset exits zero");

    my $builds = {};
    for my $build ($jobset->builds) {
        $builds->{$build->job} = $build;
    }

    subtest "basic globbing works" => sub {
        ok(defined $builds->{"ok_aggregate"}, "'ok_aggregate' is part of the jobset evaluation");
        my @constituents = $builds->{"ok_aggregate"}->constituents->all;
        is(2, scalar @constituents, "'ok_aggregate' has two constituents");

        my @sortedConstituentNames = sort (map { $_->nixname } @constituents);

        is($sortedConstituentNames[0], "empty-dir-A", "first constituent of 'ok_aggregate' is 'empty-dir-A'");
        is($sortedConstituentNames[1], "empty-dir-B", "second constituent of 'ok_aggregate' is 'empty-dir-B'");
    };

    subtest "transitivity is OK" => sub {
        ok(defined $builds->{"indirect_aggregate"}, "'indirect_aggregate' is part of the jobset evaluation");
        my @constituents = $builds->{"indirect_aggregate"}->constituents->all;
        is(1, scalar @constituents, "'indirect_aggregate' has one constituent");
        is($constituents[0]->nixname, "direct_aggregate", "'indirect_aggregate' has 'direct_aggregate' as single constituent");
    };
};

subtest "* selects all except current aggregate" => sub {
    my $jobsetCtx = $ctx->makeJobset(
        expression => 'constituents-glob-all.nix',
    );
    my $jobset = $jobsetCtx->{"jobset"};

    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        ("hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name)
    );

    subtest "no eval errors" => sub {
        ok(utf8::decode($stderr), "Stderr output is UTF8-clean");
        ok(
            $stderr !~ "aggregate job ‘ok_aggregate’ has a constituent .* that doesn't correspond to a Hydra build",
            "Catchall wildcard must not select itself as constituent"
        );

        $jobset->discard_changes;  # refresh from DB
        is(
            $jobset->has_error,
            0,
            "eval-errors non-empty"
        );
    };

    my $builds = {};
    for my $build ($jobset->builds) {
        $builds->{$build->job} = $build;
    }

    subtest "two constituents" => sub {
        ok(defined $builds->{"ok_aggregate"}, "'ok_aggregate' is part of the jobset evaluation");
        my @constituents = $builds->{"ok_aggregate"}->constituents->all;
        is(2, scalar @constituents, "'ok_aggregate' has two constituents");

        my @sortedConstituentNames = sort (map { $_->nixname } @constituents);

        is($sortedConstituentNames[0], "empty-dir-A", "first constituent of 'ok_aggregate' is 'empty-dir-A'");
        is($sortedConstituentNames[1], "empty-dir-B", "second constituent of 'ok_aggregate' is 'empty-dir-B'");
    };
};

subtest "trivial cycle check" => sub {
    my $jobsetCtx = $ctx->makeJobset(
        expression => 'constituents-cycle.nix',
    );
    my $jobset = $jobsetCtx->{"jobset"};

    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        ("hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name)
    );

    ok(
        $stderr =~ "Found dependency cycle between jobs 'indirect_aggregate' and 'ok_aggregate'",
        "Dependency cycle error is on stderr"
    );

    ok(utf8::decode($stderr), "Stderr output is UTF8-clean");

    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });  # refresh from DB
    like(
        $jobset->errormsg,
        qr/Dependency cycle: indirect_aggregate <-> ok_aggregate/,
        "eval-errors non-empty"
    );

    is(0, $jobset->builds->count, "No builds should be scheduled");
};

subtest "cycle check with globbing" => sub {
    my $jobsetCtx = $ctx->makeJobset(
        expression => 'constituents-cycle-glob.nix',
    );
    my $jobset = $jobsetCtx->{"jobset"};

    my ($res, $stdout, $stderr) = captureStdoutStderr(60,
        ("hydra-eval-jobset", $jobsetCtx->{"project"}->name, $jobset->name)
    );

    ok(utf8::decode($stderr), "Stderr output is UTF8-clean");

    $jobset->discard_changes({ '+columns' => {'errormsg' => 'errormsg'} });  # refresh from DB
    like(
        $jobset->errormsg,
        qr/aggregate job ‘indirect_aggregate’ failed with the error: Dependency cycle: indirect_aggregate <-> packages.constituentA/,
        "packages.constituentA error missing"
    );

    # on this branch of Hydra, hydra-eval-jobset fails hard if an aggregate
    # job is broken.
    is(0, $jobset->builds->count, "Zero jobs are scheduled");
};

done_testing;

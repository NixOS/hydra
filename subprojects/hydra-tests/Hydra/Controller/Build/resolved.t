use strict;
use warnings;
use Setup;
use JSON::MaybeXS qw(decode_json);
use Nix::Config;
use Test2::V0;
use HTTP::Request::Common;

my %ctx = test_init();
setup_catalyst_test($ctx{context});

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({
    name => "tests", displayname => "", owner => "root",
});
my $jobset = createBaseJobset($db, "basic", "basic.nix", $ctx{jobsdir});
ok(evalSucceeds($ctx{context}, $jobset), "Evaluating basic.nix succeeds");
my @builds = queuedBuildsForJobset($jobset);
my ($build) = grep { $_->nixname eq "empty-dir" } @builds;
ok(defined $build, "got a build out of the jobset");

my $resolvedBasename = "00000000000000000000000000000001-resolved.drv";
my $storeDir = $Nix::Config::storeDir;
my $unresolvedDrv = "$storeDir/00000000000000000000000000000000-unresolved.drv";

# Step 101: Resolved with terminal at step 102 (Succeeded).
$db->resultset('BuildSteps')->create({
    build           => $build->id,
    stepnr          => 101,
    type            => 0,
    drvpath         => $unresolvedDrv,
    busy            => 0,
    status          => 13,
    machine         => "",
    resolveddrvpath => $resolvedBasename,
});

$db->resultset('BuildSteps')->create({
    build     => $build->id,
    stepnr    => 102,
    type      => 0,
    drvpath   => "$storeDir/$resolvedBasename",
    busy      => 0,
    status    => 0,
    stoptime  => 1000,
    machine   => "",
});

# Step 103: Resolved but terminal drv has no buildstep row yet.
$db->resultset('BuildSteps')->create({
    build           => $build->id,
    stepnr          => 103,
    type            => 0,
    drvpath         => "$storeDir/00000000000000000000000000000002-unresolved2.drv",
    busy            => 0,
    status          => 13,
    machine         => "",
    resolveddrvpath => "00000000000000000000000000000099-missing.drv",
});

my $buildUrl = "/build/" . $build->id;

subtest "log of a Resolved step 302s to the terminal step's log" => sub {
    my $r = request(GET "$buildUrl/step/101/log");
    is($r->code, 302, "GET log of Resolved step redirects");
    my $loc = $r->header('location') // "";
    like($loc, qr{/build/\Q@{[$build->id]}\E/step/102/log},
         "Location points at terminal step's log");
};

subtest "page of a Resolved step renders Resolution layout with terminal link" => sub {
    my $r = request(GET "$buildUrl/step/101");
    is($r->code, 200, "step page renders");
    like($r->content, qr/Resolution/,
         "Type cell shows Resolution");
    like($r->content, qr/unresolved\.drv/,
         "page shows the original (pre-resolution) derivation");
    like($r->content, qr/\Q$resolvedBasename\E/,
         "page shows the resolved drv basename");
    like($r->content, qr/step #102/,
         "page links to the terminal step");
};

subtest "page of a Resolved step whose terminal is missing renders pending state" => sub {
    my $r = request(GET "$buildUrl/step/103");
    is($r->code, 200, "missing-terminal page renders");
    like($r->content, qr/missing\.drv/,
         "page names the missing resolved drv");
    like($r->content, qr/not yet scheduled/i,
         "page describes the unscheduled state");
};

subtest "log of a Resolved step with no terminal redirects to its page" => sub {
    my $r = request(GET "$buildUrl/step/103/log");
    is($r->code, 302, "log endpoint still redirects");
    my $loc = $r->header('location') // "";
    like($loc, qr{/build/\Q@{[$build->id]}\E/step/103$},
         "redirects to step page, not a log URL");
};

subtest "get-info JSON exposes resolvedSteps" => sub {
    my $r = request(GET "$buildUrl/api/get-info", Accept => 'application/json');
    is($r->code, 200, "api/get-info responds");
    my $data = decode_json($r->content);
    ok($data->{resolvedSteps}, "resolvedSteps key present");
    is(scalar @{$data->{resolvedSteps}}, 2, "two resolved steps reported");
    my ($terminalEntry) = grep { $_->{stepnr} == 101 } @{$data->{resolvedSteps}};
    is($terminalEntry->{resolvedDrvPath}, $resolvedBasename,
       "step 101 reports resolved basename");
    is($terminalEntry->{terminal}{stepnr}, 102,
       "step 101 terminal is step 102");
    is($terminalEntry->{terminal}{status}, 0,
       "terminal status is Success");
};

subtest "self-referential resolved step renders cycle copy on its page" => sub {
    my $cycleBasename = "00000000000000000000000000000003-cycle.drv";
    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 104,
        type            => 0,
        drvpath         => "$storeDir/$cycleBasename",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => $cycleBasename,
    });
    my $r = request(GET "$buildUrl/step/104");
    is($r->code, 200, "self-cycle page renders");
    like($r->content, qr/cycles back/i,
         "page describes the cycle, not 'not yet scheduled'");

    my $logR = request(GET "$buildUrl/step/104/log");
    is($logR->code, 302, "log endpoint redirects");
    like($logR->header('location') // "",
         qr{/build/\Q@{[$build->id]}\E/step/104$},
         "self-cycle log redirects to the step page");
};

subtest "terminal log carries a 'resolution target' banner" => sub {
    my $r = request(GET "$buildUrl/step/102/log");
    is($r->code, 200, "terminal log renders");
    like($r->content, qr/resolution target/i,
         "banner labels the relation, not a redirect");
    like($r->content, qr/step #101/,
         "banner names the resolved origin");
    like($r->content, qr/Original derivation.*unresolved\.drv/s,
         "banner shows the original (pre-resolution) drvpath");
};

subtest "page with running terminal shows Running status" => sub {
    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 200,
        type            => 0,
        drvpath         => "$storeDir/00000000000000000000000000000020-pending-orig.drv",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => "00000000000000000000000000000021-busy-terminal.drv",
    });
    $db->resultset('BuildSteps')->create({
        build     => $build->id,
        stepnr    => 201,
        type      => 0,
        drvpath   => "$storeDir/00000000000000000000000000000021-busy-terminal.drv",
        busy      => 1,
        status    => undef,
        machine   => "builder-a",
        starttime => 500,
    });
    my $r = request(GET "$buildUrl/step/200");
    is($r->code, 200, "page renders for busy-terminal case");
    like($r->content, qr/Running/,
         "status shows Running for the busy terminal");
    like($r->content, qr/step #201/,
         "names the running step");

    my $logR = request(GET "$buildUrl/step/200/log");
    is($logR->code, 302, "log endpoint redirects");
    like($logR->header('location') // "",
         qr{/build/\Q@{[$build->id]}\E/step/200$},
         "running terminal has no log yet, redirects back to step page");
};

subtest "cross-build scoping: chain does not reach into other builds" => sub {
    my $buildB = $db->resultset('Builds')->create({
        finished    => 1,
        timestamp   => 0,
        jobset_id   => $build->jobset_id,
        job         => "empty-dir",
        nixname     => "empty-dir",
        drvpath     => "$storeDir/00000000000000000000000000000040-other-unresolved.drv",
        system      => "x86_64-linux",
        starttime   => 1, stoptime => 1,
        buildstatus => 0, iscurrent => 0,
    });

    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 301,
        type            => 0,
        drvpath         => "$storeDir/00000000000000000000000000000040-origA.drv",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => "00000000000000000000000000000041-collide.drv",
    });

    $db->resultset('BuildSteps')->create({
        build     => $buildB->id,
        stepnr    => 500,
        type      => 0,
        drvpath   => "$storeDir/00000000000000000000000000000041-collide.drv",
        busy      => 0,
        status    => 0,
        stoptime  => 1000,
        machine   => "",
    });

    my $r = request(GET "$buildUrl/step/301");
    is($r->code, 200, "page renders without chasing cross-build terminal");
    like($r->content, qr/not yet scheduled/i,
         "chain stops at build boundary");
};

subtest "sibling steps with shared terminal redirect to the same target" => sub {
    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 400,
        type            => 0,
        drvpath         => "$storeDir/00000000000000000000000000000050-first.drv",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => "00000000000000000000000000000051-shared.drv",
    });
    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 401,
        type            => 0,
        drvpath         => "$storeDir/00000000000000000000000000000060-second.drv",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => "00000000000000000000000000000051-shared.drv",
    });
    $db->resultset('BuildSteps')->create({
        build     => $build->id,
        stepnr    => 402,
        type      => 0,
        drvpath   => "$storeDir/00000000000000000000000000000051-shared.drv",
        busy      => 0,
        status    => 0,
        stoptime  => 1000,
        machine   => "",
    });

    for my $origin (400, 401) {
        my $r = request(GET "$buildUrl/step/$origin/log");
        is($r->code, 302, "step $origin log redirects (no false cycle)");
        like($r->header('location') // "", qr{/step/402/log},
             "step $origin lands on the shared terminal's log");
    }

    my $term = request(GET "$buildUrl/step/402/log");
    is($term->code, 200, "shared terminal log renders");
    like($term->content, qr/resolution target of:/i,
         "banner enters the multi-origin form when more than one step resolved here");
    like($term->content, qr/step #400/, "banner lists step 400");
    like($term->content, qr/step #401/, "banner lists step 401");
};

subtest "corrupt resolveddrvpath does not crash or chase" => sub {
    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 500,
        type            => 0,
        drvpath         => "$storeDir/00000000000000000000000000000070-corrupt.drv",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => "../../etc/passwd",
    });
    my $r = request(GET "$buildUrl/step/500");
    is($r->code, 200, "corrupt basename does not crash");
    like($r->content, qr/not yet scheduled/i,
         "falls through to pending state rather than following the hop");
};

subtest "multi-step resolution cycle is classified as cycle" => sub {
    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 600,
        type            => 0,
        drvpath         => "$storeDir/00000000000000000000000000000080-cycle-a.drv",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => "00000000000000000000000000000081-cycle-b.drv",
    });
    $db->resultset('BuildSteps')->create({
        build           => $build->id,
        stepnr          => 601,
        type            => 0,
        drvpath         => "$storeDir/00000000000000000000000000000081-cycle-b.drv",
        busy            => 0,
        status          => 13,
        machine         => "",
        resolveddrvpath => "00000000000000000000000000000080-cycle-a.drv",
    });
    my $r = request(GET "$buildUrl/step/600");
    is($r->code, 200, "page renders for multi-step cycle");
    like($r->content, qr/cycles back/i,
         "multi-step cycle uses the cycle copy");
};

subtest "raw log mode propagates through the resolved redirect" => sub {
    my $r = request(GET "$buildUrl/step/101/log/raw");
    is($r->code, 302, "raw on a resolved step still redirects");
    like($r->header('location') // "", qr{/step/102/log/raw},
         "raw mode is preserved in the redirect target");
};

subtest "old /nixlog/:nr URL still 301-redirects to /step/:nr/log" => sub {
    my $r = request(GET "$buildUrl/nixlog/101");
    is($r->code, 301, "old nixlog URL 301s to the step log endpoint");
    like($r->header('location') // "", qr{/step/101/log},
         "preserves stepnr in the redirect target");
};

done_testing;

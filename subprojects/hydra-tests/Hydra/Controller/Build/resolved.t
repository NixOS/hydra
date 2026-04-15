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

subtest "nixlog for a Resolved step 302s to the terminal" => sub {
    my $r = request(GET "$buildUrl/nixlog/101");
    is($r->code, 302, "GET nixlog of Resolved step redirects");
    my $loc = $r->header('location') // "";
    like($loc, qr{/build/\Q@{[$build->id]}\E/nixlog/102}, "Location points at terminal step");
};

subtest "nixlog for a Resolved step whose terminal is missing renders pending template" => sub {
    my $r = request(GET "$buildUrl/nixlog/103");
    is($r->code, 200, "pending case returns 200, not a redirect");
    like($r->content, qr/resolved, log pending/i, "body mentions pending");
    like($r->content, qr/missing\.drv/, "body names the missing resolved drv");
    like($r->content, qr/has been scheduled yet|will refresh automatically/,
         "copy describes the unscheduled state, not a running one");
};

subtest "get-info JSON exposes resolvedSteps" => sub {
    my $r = request(GET "$buildUrl/api/get-info", Accept => 'application/json');
    is($r->code, 200, "api/get-info responds");
    my $data = decode_json($r->content);
    ok($data->{resolvedSteps}, "resolvedSteps key present");
    is(scalar @{$data->{resolvedSteps}}, 2, "two resolved steps reported");
    my ($terminalEntry) = grep { $_->{stepnr} == 101 } @{$data->{resolvedSteps}};
    is($terminalEntry->{resolvedDrvPath}, $resolvedBasename, "step 101 reports resolved basename");
    is($terminalEntry->{terminal}{stepnr}, 102, "step 101 terminal is step 102");
    is($terminalEntry->{terminal}{status}, 0, "terminal status is Success");
};

subtest "cycle guard: self-referencing resolved step does not loop" => sub {
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
    my $r = request(GET "$buildUrl/nixlog/104");
    is($r->code, 200, "self-cycle does not infinite-loop");
    like($r->content, qr/self-referential/i,
         "self-cycle copy names the failure mode, not 'not yet scheduled'");
};

subtest "terminal log URL is shareable (banner rendered from DB, not flash)" => sub {
    my $r = request(GET "$buildUrl/nixlog/102");
    is($r->code, 200, "terminal log renders");
    like($r->content, qr/Redirected here from/,
         "banner present without a preceding redirect in the session");
    like($r->content, qr/step #101/, "banner names the resolved origin");
    like($r->content, qr/Original derivation.*unresolved\.drv/s,
         "banner shows the original (pre-resolution) drvpath");
};

subtest "pending page with running terminal says 'currently running'" => sub {
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
    my $r = request(GET "$buildUrl/nixlog/200");
    is($r->code, 200, "busy-terminal case renders pending, not a redirect");
    like($r->content, qr/currently running/i,
         "pending copy distinguishes 'running' from 'unscheduled'");
    like($r->content, qr/step #201/, "names the running step");
    like($r->content, qr/http-equiv="refresh"/,
         "auto-refresh enabled so page updates when terminal finishes");
};

subtest "pending page with unscheduled terminal does not auto-refresh self-cycle" => sub {
    my $r = request(GET "$buildUrl/nixlog/104");
    unlike($r->content, qr/http-equiv="refresh"/,
           "self-cycle never resolves, so no meta-refresh spin");
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

    my $r = request(GET "$buildUrl/nixlog/301");
    is($r->code, 200, "no cross-build terminal -> pending, not redirect");
    like($r->content, qr/resolved, log pending/i,
         "chain stops at build boundary, renders pending template");
};

subtest "cycle detection: two siblings sharing resolveddrvpath don't false-cycle" => sub {
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
        my $r = request(GET "$buildUrl/nixlog/$origin");
        is($r->code, 302, "step $origin redirects (no false cycle)");
        like($r->header('location') // "", qr{/nixlog/402},
             "step $origin lands on the shared terminal");
    }
};

subtest "basename validation: resolveddrvpath with a slash is rejected" => sub {
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
    my $r = request(GET "$buildUrl/nixlog/500");
    is($r->code, 200, "corrupt basename does not crash or chase");
    like($r->content, qr/resolved, log pending/i,
         "falls through to pending page rather than following the hop");
};

subtest "multi-step resolution cycle is classified as cycle, not unscheduled" => sub {
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
    my $r = request(GET "$buildUrl/nixlog/600");
    is($r->code, 200, "multi-step cycle renders pending, not redirect");
    like($r->content, qr/self-referential|never produce/i,
         "multi-step cycle uses the cycle copy, not 'unscheduled'");
    unlike($r->content, qr/http-equiv="refresh"/,
           "multi-step cycle does not auto-refresh");
};

subtest "raw mode on a Resolved step does not set a lingering flash banner" => sub {
    my $r1 = request(GET "$buildUrl/nixlog/101/raw");
    is($r1->code, 302, "raw on a resolved step still redirects");
    my $r2 = request(GET "/");
    unlike($r2->content, qr/Redirected here from/,
           "no lingering flash banner on unrelated page");
};

done_testing;

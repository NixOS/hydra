use strict;
use warnings;
use Setup;
use Test2::V0;
use HTTP::Request;
use HTTP::Request::Common;
use JSON::MaybeXS qw(decode_json encode_json);
use Digest::SHA qw(hmac_sha256_hex);
use URI;

sub is_json {
    my ($response, $message) = @_;

    my $data;
    my $valid_json = lives { $data = decode_json($response->content); };
    ok($valid_json, $message // "We get back valid JSON.");
    if (!$valid_json) {
        use Data::Dumper;
        print STDERR Dumper $response->content;
    }

    return $data;
}

sub latestbuilds_url {
    my (%params) = @_;
    my $uri = URI->new('/api/latestbuilds');
    $uri->query_form(%params);
    return $uri->as_string;
}

my $ctx = test_context(hydra_config => qq|
    <webhooks>
        <github>
            secret = test
        </github>
    </webhooks>
|);
setup_catalyst_test($ctx);

# Create a user to log in to
my $user = $ctx->db->resultset('Users')->create({ username => 'alice', emailaddress => 'alice@example.com', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

# Login and save cookie for future requests
my $req = request(POST '/login',
    Referer => 'http://localhost/',
    Content => {
        username => 'alice',
        password => 'foobar'
    }
);
is($req->code, 302, "The login redirects");
my $cookie = $req->header("set-cookie");

my $finishedBuilds = $ctx->makeAndEvaluateJobset(
    expression => "one-job.nix",
    build => 1
);

my $queuedBuilds = $ctx->makeAndEvaluateJobset(
    expression => "one-job.nix",
    build => 0
);

subtest "/api/queue" => sub {
    my $response = request(GET '/api/queue?nr=1');
    ok($response->is_success, "The API enpdoint showing the queue returns 200.");

    my $data = is_json($response);
    my $build = $queuedBuilds->{"one_job"};
    like($data, [{
        priority => $build->priority,
        id => $build->id,
    }]);
};

subtest "/api/latestbuilds" => sub {
    my $sourceBuild = $finishedBuilds->{"one_job"};
    my $projectName = $sourceBuild->project->name;
    my $jobsetName = $sourceBuild->jobset->name;
    my $jobName = 'history_job';
    my $system = 'x86_64-linux';

    my @historySpecs = (
        { stoptime => 200, buildstatus => 0, releasename => 'history-release' },
        { stoptime => 300, buildstatus => 1 },
        { stoptime => 300, buildstatus => 4 },
        { stoptime => 100, buildstatus => 0 },
    );
    my @historyBuilds;
    for my $i (0 .. $#historySpecs) {
        my $spec = $historySpecs[$i];
        push @historyBuilds, $ctx->db->resultset('Builds')->create({
            finished => 1,
            timestamp => 10 + $i,
            jobset_id => $sourceBuild->jobset_id,
            job => $jobName,
            nixname => "history-$i",
            drvpath => "/nix/store/0000000000000000000000000000000$i-history.drv",
            system => $system,
            starttime => 1,
            stoptime => $spec->{stoptime},
            buildstatus => $spec->{buildstatus},
            releasename => $spec->{releasename},
        });
    }

    my $otherProject = $ctx->db->resultset('Projects')->create({
        name => 'latestbuilds-other-project',
        displayname => 'Latest Builds Other Project',
        owner => $user->username,
    });
    my $otherProjectJobset = $otherProject->jobsets->create({
        name => $jobsetName,
        nixexprinput => 'src',
        nixexprpath => 'default.nix',
        emailoverride => '',
    });
    $ctx->db->resultset('Builds')->create({
        finished => 1,
        timestamp => 18,
        jobset_id => $otherProjectJobset->id,
        job => $jobName,
        nixname => 'other-project',
        drvpath => '/nix/store/00000000000000000000000000000007-other-project.drv',
        system => $system,
        starttime => 1,
        stoptime => 600,
        buildstatus => 0,
    });

    my $sameProjectOtherJobset = $sourceBuild->project->jobsets->create({
        name => 'latestbuilds-other-jobset',
        nixexprinput => 'src',
        nixexprpath => 'default.nix',
        emailoverride => '',
    });
    $ctx->db->resultset('Builds')->create({
        finished => 1,
        timestamp => 19,
        jobset_id => $sameProjectOtherJobset->id,
        job => $jobName,
        nixname => 'other-jobset',
        drvpath => '/nix/store/00000000000000000000000000000008-other-jobset.drv',
        system => $system,
        starttime => 1,
        stoptime => 700,
        buildstatus => 0,
    });

    my $otherSystemBuild = $ctx->db->resultset('Builds')->create({
        finished => 1,
        timestamp => 20,
        jobset_id => $sourceBuild->jobset_id,
        job => $jobName,
        nixname => 'other-system',
        drvpath => '/nix/store/00000000000000000000000000000004-other-system.drv',
        system => 'aarch64-linux',
        starttime => 1,
        stoptime => 400,
        buildstatus => 0,
    });

    my $otherJobBuild = $ctx->db->resultset('Builds')->create({
        finished => 1,
        timestamp => 21,
        jobset_id => $sourceBuild->jobset_id,
        job => 'other_history_job',
        nixname => 'other-job',
        drvpath => '/nix/store/00000000000000000000000000000005-other-job.drv',
        system => $system,
        starttime => 1,
        stoptime => 500,
        buildstatus => 0,
    });

    $ctx->db->resultset('Builds')->create({
        finished => 0,
        timestamp => 22,
        jobset_id => $sourceBuild->jobset_id,
        job => $jobName,
        nixname => 'unfinished',
        drvpath => '/nix/store/00000000000000000000000000000006-unfinished.drv',
        system => $system,
    });

    my @legacyFields = sort qw(
        buildstatus finished id job jobset nixname project system timestamp
    );
    my @historyFields = sort (@legacyFields, qw(releasename stoptime));

    subtest "legacy ordering and response shape" => sub {
        my $response = request(GET latestbuilds_url(nr => 1));
        ok($response->is_success, "The latest builds API returns 200.");

        my $data = is_json($response);
        is(scalar @{$data}, 1, "Legacy nr bounds the response.");
        is($data->[0]->{id}, $otherJobBuild->id, "Legacy mode orders finished builds by descending ID.");
        is([sort keys %{$data->[0]}], \@legacyFields, "Legacy mode keeps its original field set.");
        is($response->header('Link'), undef, "Legacy mode doesn't emit a pagination link.");
    };

    subtest "limit is the preferred legacy count parameter" => sub {
        my $response = request(GET latestbuilds_url(limit => 1));
        ok($response->is_success, "The preferred count parameter returns 200.");

        my $data = is_json($response);
        is(scalar @{$data}, 1, "Preferred limit bounds the response.");
        is($data->[0]->{id}, $otherJobBuild->id, "limit preserves legacy ID ordering when order is omitted.");
        is([sort keys %{$data->[0]}], \@legacyFields, "limit doesn't change the legacy response shape.");
    };

    subtest "the documented maximum is accepted" => sub {
        for my $name (qw(limit nr)) {
            my $response = request(GET latestbuilds_url($name => 100));
            ok($response->is_success, "$name accepts the documented maximum.");
            ok(scalar @{is_json($response)} >= 1, "$name=100 returns available finished builds.");
        }
    };

    subtest "legacy filters retain ID ordering" => sub {
        my $response = request(GET latestbuilds_url(
            nr => 1,
            project => $projectName,
            jobset => $jobsetName,
            job => $jobName,
            system => $system,
        ));
        ok($response->is_success, "A fully filtered legacy request returns 200.");

        my $data = is_json($response);
        is($data->[0]->{id}, $historyBuilds[3]->id, "Legacy filters still return the highest matching build ID.");
        is([sort keys %{$data->[0]}], \@legacyFields, "Filtered legacy results keep their original field set.");
    };

    subtest "completion ordering and history fields" => sub {
        my $response = request(GET latestbuilds_url(
            limit => 10,
            order => 'stoptime',
            project => $projectName,
            jobset => $jobsetName,
            job => $jobName,
            system => $system,
        ));
        ok($response->is_success, "A completion-history request returns 200.");

        my $data = is_json($response);
        is(
            [map { $_->{id} } @{$data}],
            [map { $_->id } @historyBuilds[2, 1, 0, 3]],
            "History is ordered by completion time and then descending ID.",
        );
        is(
            [map { $_->{buildstatus} } @{$data}],
            [4, 1, 0, 0],
            "Successful, failed, and cancelled finished builds remain in history.",
        );
        is([sort keys %{$data->[0]}], \@historyFields, "History results add only stoptime and releasename.");
        ok(!grep(!defined($_->{stoptime}), @{$data}), "Every history result has a completion time.");

        my %byId = map { $_->{id} => $_ } @{$data};
        is($byId{$historyBuilds[0]->id}->{releasename}, 'history-release', "History exposes a release name when present.");
        is($byId{$historyBuilds[1]->id}->{releasename}, undef, "History preserves a null release name.");
        is($response->header('Link'), undef, "A terminal history page doesn't emit a pagination link.");

        my $exactResponse = request(GET latestbuilds_url(
            limit => 4,
            order => 'stoptime',
            project => $projectName,
            jobset => $jobsetName,
            job => $jobName,
            system => $system,
        ));
        ok($exactResponse->is_success, "An exactly full terminal page returns 200.");
        is(scalar @{is_json($exactResponse)}, 4, "An exactly full terminal page returns every matching build.");
        is($exactResponse->header('Link'), undef, "An exactly full terminal page doesn't emit a next link.");
    };

    subtest "system is an optional history filter" => sub {
        my $response = request(GET latestbuilds_url(
            limit => 10,
            order => 'stoptime',
            project => $projectName,
            jobset => $jobsetName,
            job => $jobName,
        ));
        ok($response->is_success, "History can be requested without a system filter.");

        my $data = is_json($response);
        is(
            [map { $_->{id} } @{$data}],
            [$otherSystemBuild->id, map { $_->id } @historyBuilds[2, 1, 0, 3]],
            "Omitting system includes matching builds for every system.",
        );

        my $pagedResponse = request(GET latestbuilds_url(
            limit => 1,
            order => 'stoptime',
            project => $projectName,
            jobset => $jobsetName,
            job => $jobName,
        ));
        ok($pagedResponse->is_success, "Paginated history without a system filter returns 200.");
        my $pagedLink = $pagedResponse->header('Link');
        like($pagedLink, qr{\A<https?://[^>]+>; rel="next"\z}, "Paginated history without a system filter has a next link.");
        my ($nextUrl) = $pagedLink =~ m{\A<([^>]+)>};
        my %nextQuery = URI->new($nextUrl)->query_form;
        ok(!exists $nextQuery{system}, "A next link doesn't add an omitted system filter.");
    };

    subtest "scope filters are enforced" => sub {
        for my $case (
            [project => 'missing-project'],
            [jobset => 'missing-jobset'],
            [job => 'missing-job'],
        ) {
            my %scope = (
                project => $projectName,
                jobset => $jobsetName,
                job => $jobName,
                @{$case},
            );
            my $response = request(GET latestbuilds_url(
                limit => 10,
                order => 'stoptime',
                %scope,
            ));
            ok($response->is_success, "A valid but unmatched scope returns 200.");
            is(is_json($response), [], $case->[0] . " filters the history query.");
        }
    };

    subtest "cursor pagination has no duplicates or omissions" => sub {
        my %scope = (
            order => 'stoptime',
            project => $projectName,
            jobset => $jobsetName,
            job => $jobName,
            system => $system,
        );
        my $firstResponse = request(GET latestbuilds_url(%scope, nr => 1));
        ok($firstResponse->is_success, "The first history page returns 200.");
        my $firstPage = is_json($firstResponse);
        is([map { $_->{id} } @{$firstPage}], [$historyBuilds[2]->id], "The first page contains the newest tied completion.");

        my $link = $firstResponse->header('Link');
        like($link, qr{\A<https?://[^>]+>; rel="next"\z}, "A non-terminal page has one absolute next link.");
        my ($nextUrl) = $link =~ m{\A<([^>]+)>};
        my $nextUri = URI->new($nextUrl);
        my %nextQuery = $nextUri->query_form;
        is($nextUri->scheme, 'http', "The next link preserves the request scheme.");
        is($nextUri->host, 'localhost', "The next link preserves the request host.");
        is($nextUri->port, 80, "The next link preserves the request port.");
        is($nextQuery{limit}, 1, "The next link uses canonical limit.");
        ok(!exists $nextQuery{nr}, "The next link doesn't repeat the legacy count alias.");
        is($nextQuery{cursor}, 'v1:300:' . $historyBuilds[2]->id, "The cursor is exclusive of the last returned completion.");
        is($nextQuery{order}, 'stoptime', "The next link preserves completion ordering.");
        is($nextQuery{project}, $projectName, "The next link preserves project scope.");
        is($nextQuery{jobset}, $jobsetName, "The next link preserves jobset scope.");
        is($nextQuery{job}, $jobName, "The next link preserves job scope.");
        is($nextQuery{system}, $system, "The next link preserves system scope.");

        my @seen = map { $_->{id} } @{$firstPage};
        my @remaining = @historyBuilds[1, 0, 3];
        my $pageResponse;
        for my $i (0 .. $#remaining) {
            $pageResponse = request(GET $nextUri->as_string);
            ok($pageResponse->is_success, "Following history page " . ($i + 2) . " returns 200.");
            my $page = is_json($pageResponse);
            is([map { $_->{id} } @{$page}], [$remaining[$i]->id], "History page " . ($i + 2) . " contains the expected build.");
            push @seen, map { $_->{id} } @{$page};

            my $pageLink = $pageResponse->header('Link');
            if ($i < $#remaining) {
                like($pageLink, qr{\A<https?://[^>]+>; rel="next"\z}, "History page " . ($i + 2) . " has a next link.");
                my ($pageUrl) = $pageLink =~ m{\A<([^>]+)>};
                $nextUri = URI->new($pageUrl);
            } else {
                is($pageLink, undef, "The terminal page has no next link.");
            }
        }
        is(\@seen, [map { $_->id } @historyBuilds[2, 1, 0, 3]], "Following links traverses tied completion times without duplicates or omissions.");

        my $emptyResponse = request(GET latestbuilds_url(
            %scope,
            limit => 1,
            cursor => 'v1:100:' . $historyBuilds[3]->id,
        ));
        ok($emptyResponse->is_success, "A cursor beyond the available history returns 200.");
        is(is_json($emptyResponse), [], "A cursor beyond the available history returns an empty array.");
        is($emptyResponse->header('Link'), undef, "An empty page has no next link.");
    };

    subtest "invalid requests return JSON 400 errors" => sub {
        my @invalidRequests = (
            [latestbuilds_url(), 'missing count'],
            [latestbuilds_url(limit => 1, nr => 1), 'conflicting count parameters'],
            [latestbuilds_url(limit => 0), 'zero limit'],
            [latestbuilds_url(limit => -1), 'negative limit'],
            [latestbuilds_url(limit => '1.5'), 'fractional limit'],
            [latestbuilds_url(limit => 'one'), 'non-numeric limit'],
            [latestbuilds_url(limit => 101), 'above-maximum limit'],
            [latestbuilds_url(nr => 0), 'zero legacy count'],
            [latestbuilds_url(nr => -1), 'negative legacy count'],
            [latestbuilds_url(nr => '1.5'), 'fractional legacy count'],
            [latestbuilds_url(nr => 'one'), 'non-numeric legacy count'],
            [latestbuilds_url(nr => 101), 'above-maximum legacy count'],
            [latestbuilds_url(limit => 1, order => 'timestamp'), 'unsupported ordering'],
            [latestbuilds_url(limit => 1, cursor => 'v1:1:1'), 'cursor without history ordering'],
            [latestbuilds_url(limit => 1, order => 'stoptime', jobset => $jobsetName, job => $jobName), 'missing project scope'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => '', jobset => $jobsetName, job => $jobName), 'empty project scope'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, job => $jobName), 'missing jobset scope'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => '', job => $jobName), 'empty jobset scope'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName), 'missing job scope'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => ''), 'empty job scope'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => $jobName, cursor => 'invalid'), 'malformed cursor'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => $jobName, cursor => 'v2:1:1'), 'unknown cursor version'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => $jobName, cursor => 'v1:0:1'), 'zero cursor completion time'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => $jobName, cursor => 'v1:1:0'), 'zero cursor build ID'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => $jobName, cursor => 'v1:-1:1'), 'negative cursor completion time'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => $jobName, cursor => 'v1:1.5:1'), 'fractional cursor completion time'],
            [latestbuilds_url(limit => 1, order => 'stoptime', project => $projectName, jobset => $jobsetName, job => $jobName, cursor => 'v1:2147483648:1'), 'overflowing cursor completion time'],
        );

        for my $case (@invalidRequests) {
            my ($url, $description) = @{$case};
            my $response = request(GET $url);
            is($response->code, 400, "$description returns 400.");
            like($response->header('Content-Type'), qr{\Aapplication/json}, "$description returns JSON.");
            like(is_json($response), {error => D()}, "$description returns an error object.");
        }
    };
};

subtest "/api/nrbuilds" => sub {
    subtest "with no specific parameters" => sub {
        my $response = request(GET '/api/nrbuilds?nr=1&period=hour');
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data = is_json($response);
        is($data, [1]);
    };

    subtest "with very specific parameters" => sub {
        my $build = $finishedBuilds->{"one_job"};
        my $projectName = $build->project->name;
        my $jobsetName = $build->jobset->name;
        my $jobName = $build->job;
        my $system = $build->system;
        my $response = request(GET "/api/nrbuilds?nr=1&period=hour&project=$projectName&jobset=$jobsetName&job=$jobName&system=$system");
        ok($response->is_success, "The API enpdoint showing the latest builds returns 200.");

        my $data = is_json($response);
        is($data, [1]);
    };
};

subtest "/api/push" => sub {
    subtest "with a specific jobset" => sub {
        my $build = $finishedBuilds->{"one_job"};
        my $jobset = $build->jobset;
        my $projectName = $jobset->project->name;
        my $jobsetName = $jobset->name;
        is($jobset->forceeval, undef, "The existing jobset is not set to be forced to eval");

        my $response = request(POST "/api/push?jobsets=$projectName:$jobsetName&force=1",
            Cookie => $cookie,
            Referer => 'http://localhost/',
        );
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is($data, { jobsetsTriggered => [ "$projectName:$jobsetName" ] });

        my $updatedJobset = $ctx->db->resultset('Jobsets')->find({ id => $jobset->id });
        is($updatedJobset->forceeval, 1, "The jobset is now forced to eval");
    };

    subtest "with a specific source" => sub {
        my $repo = $ctx->jobsdir;
        my $jobsetA = $queuedBuilds->{"one_job"}->jobset;
        my $jobsetB = $finishedBuilds->{"one_job"}->jobset;

        is($jobsetA->forceeval, undef, "The existing jobset is not set to be forced to eval");

        print STDERR $repo;

        my $response = request(POST "/api/push?repos=$repo&force=1",
            Cookie => $cookie,
            Referer => 'http://localhost/',
        );
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is($data, { jobsetsTriggered => [
            "${\$jobsetA->project->name}:${\$jobsetA->name}",
            "${\$jobsetB->project->name}:${\$jobsetB->name}"
        ] });

        my $updatedJobset = $ctx->db->resultset('Jobsets')->find({ id => $jobsetA->id });
        is($updatedJobset->forceeval, 1, "The jobset is now forced to eval");
    };
};

subtest "/api/push-github" => sub {
    # Create a project and jobset which looks like it comes from GitHub
    my $user = $ctx->db()->resultset('Users')->create({
        username => "api-push-github",
        emailaddress => 'api-push-github@example.org',
        password => ''
    });

    my $project = $ctx->db()->resultset('Projects')->create({
        name => "api-push-github",
        displayname => "api-push-github",
        owner => $user->username
    });

    subtest "with a legacy input type" => sub {
        my $jobset = $project->jobsets->create({
            name => "legacy-input-type",
            nixexprinput => "src",
            nixexprpath => "default.nix",
            emailoverride => ""
        });

        my $jobsetinput = $jobset->jobsetinputs->create({name => "src", type => "git"});
        $jobsetinput->jobsetinputalts->create({altnr => 0, value => "https://github.com/OWNER/LEGACY-REPO.git"});

        my $payload = encode_json({
            repository => {
                owner => {
                    name => "OWNER",
                },
                name => "LEGACY-REPO",
            }
        });
        my $signature = "sha256=" . hmac_sha256_hex($payload, 'test');

        my $req = POST '/api/push-github',
            "Content-Type" => "application/json",
            "X-Hub-Signature-256" => $signature,
            "Content" => $payload;

        my $response = request($req);
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is($data, { jobsetsTriggered => [ "api-push-github:legacy-input-type" ] }, "The correct jobsets are triggered.");
    };

    subtest "with a flake input type" => sub {
        my $jobset = $project->jobsets->create({
            name => "flake-input-type",
            type => 1,
            flake => "github:OWNER/FLAKE-REPO",
            emailoverride => ""
        });

        my $payload = encode_json({
            repository => {
                owner => {
                    name => "OWNER",
                },
                name => "FLAKE-REPO",
            }
        });
        my $signature = "sha256=" . hmac_sha256_hex($payload, 'test');

        my $req = POST '/api/push-github',
            "Content-Type" => "application/json",
            "X-Hub-Signature-256" => $signature,
            "Content" => $payload;

        my $response = request($req);
        ok($response->is_success, "The API enpdoint for triggering jobsets returns 200.");

        my $data = is_json($response);
        is($data, { jobsetsTriggered => [ "api-push-github:flake-input-type" ] }, "The correct jobsets are triggered.");
    };
};

done_testing;

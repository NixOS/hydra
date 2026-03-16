use strict;
use warnings;
use Setup;
use Test2::V0;

require Catalyst::Test;
use HTTP::Request::Common qw(POST PUT GET DELETE);
use JSON::MaybeXS qw(decode_json encode_json);

my $ctx = test_context(
    hydra_config => q|
    <dynamicruncommand>
    enable = 1
    </dynamicruncommand>
    |
);
Catalyst::Test->import('Hydra');

# Create a user to log in to
my $user = $ctx->db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });
$user->setPassword('foobar');
$user->userroles->update_or_create({ role => 'admin' });

subtest "can enable dynamic RunCommand when enabled by server" => sub {
    my $builds = $ctx->makeAndEvaluateJobset(
        expression => "runcommand-dynamic.nix",
        build => 1
    );

    my $build = $builds->{"runCommandHook.example"};
    my $project = $build->project;
    my $project_name = $project->name;
    my $jobset = $build->jobset;
    my $jobset_name = $jobset->name;

    is($project->enable_dynamic_run_command, 0, "dynamic RunCommand is disabled on projects by default");
    is($jobset->enable_dynamic_run_command, 0, "dynamic RunCommand is disabled on jobsets by default");

    my $req = request(POST '/login',
        Referer => 'http://localhost/',
        Content => {
            username => 'alice',
            password => 'foobar'
        }
    );
    is($req->code, 302, "logged in successfully");
    my $cookie = $req->header("set-cookie");

    subtest "can enable dynamic RunCommand on project" => sub {
        my $projectresponse = request(GET "/project/$project_name",
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
        );

        my $projectjson = decode_json($projectresponse->content);
        $projectjson->{enable_dynamic_run_command} = 1;

        my $projectupdate = request(PUT "/project/$project_name",
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
            Content => encode_json($projectjson)
        );

        $projectresponse = request(GET "/project/$project_name",
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
        );
        $projectjson = decode_json($projectresponse->content);

        is($projectupdate->code, 200);
        is($projectjson->{enable_dynamic_run_command}, JSON::MaybeXS::true);
    };

    subtest "can enable dynamic RunCommand on jobset" => sub {
        my $jobsetresponse = request(GET "/jobset/$project_name/$jobset_name",
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
        );

        my $jobsetjson = decode_json($jobsetresponse->content);
        $jobsetjson->{enable_dynamic_run_command} = 1;

        my $jobsetupdate = request(PUT "/jobset/$project_name/$jobset_name",
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
            Content => encode_json($jobsetjson)
        );

        $jobsetresponse = request(GET "/jobset/$project_name/$jobset_name",
            Accept => 'application/json',
            Content_Type => 'application/json',
            Cookie => $cookie,
        );
        $jobsetjson = decode_json($jobsetresponse->content);

        is($jobsetupdate->code, 200);
        is($jobsetjson->{enable_dynamic_run_command}, JSON::MaybeXS::true);
    };
};

done_testing;

use LWP::UserAgent;
use JSON;
use Test::Simple tests => 17;

my $ua = LWP::UserAgent->new;
$ua->cookie_jar({});

sub request_json {
    my ($opts) = @_;
    my $req = HTTP::Request->new;
    $req->method($opts->{method} or "GET");
    $req->uri("http://localhost:3000$opts->{uri}");
    $req->header(Accept => "application/json");
    $req->content(encode_json($opts->{data})) if defined $opts->{data};
    my $res = $ua->request($req);
    print $res->as_string();
    return $res;
}

my $result = request_json({ uri => "/login", method => "POST", data => { username => "root", password => "wrong" } });
ok($result->code() == 403, "Incorrect password rejected.");

my $result = request_json({ uri => "/login", method => "POST", data => { username => "root", password => "foobar" } });

my $user = decode_json($result->content());

ok($user->{username} eq "root", "The root user is named root");
ok($user->{user_roles}->[0] eq "admin", "The root user is an admin");

$user = decode_json(request_json({ uri => "/current-user" })->content());
ok($user->{username} eq "root", "The current user is named root");
ok($user->{user_roles}->[0] eq "admin", "The current user is an admin");

ok(request_json({ uri => '/project/sample' })->code() == 404, "Non-existent projects don't exist");

$result = request_json({ uri => '/project/sample', method => 'PUT', data => { displayname => "Sample", enabled => "1", } });
ok($result->code() == 201, "PUTting a new project creates it");

my $project = decode_json(request_json({ uri => '/project/sample' })->content());

ok((not @{$project->{jobsets}}), "A new project has no jobsets");

$result = request_json({ uri => '/jobset/sample/default', method => 'PUT', data => { nixexprpath => "default.nix", nixexprinput => "my-src", inputs => { "my-src" => { type => "path", properties => {value => "/run/jobset"} } }, enabled => "1", checkinterval => "3600"} });
ok($result->code() == 201, "PUTting a new jobset creates it");

my $jobset = decode_json(request_json({ uri => '/jobset/sample/default' })->content());

ok(exists $jobset->{jobset_inputs}->{"my-src"}, "The new jobset has a 'my-src' input");

ok($jobset->{jobset_inputs}->{"my-src"}->{properties}->{value} eq "/run/jobset", "The 'my-src' input is in /run/jobset");

system("hydra-evaluator sample default");
$result = request_json({ uri => '/jobset/sample/default/evals' });
ok($result->code() == 200, "Can get evals of a jobset");
my $evals = decode_json($result->content())->{evals};
my $eval = $evals->[0];
ok($eval->{has_new_builds} == 1, "The first eval of a jobset has new builds");

system("echo >> /run/jobset/default.nix; hydra-evaluator sample default");
my $evals = decode_json(request_json({ uri => '/jobset/sample/default/evals' })->content())->{evals};
ok($evals->[0]->{jobset_eval_inputs}->{"my-src"}->{revision} != $evals->[1]->{jobset_eval_inputs}->{"my-src"}->{revision}, "Changing a jobset source changes its revision");

my $build = decode_json(request_json({ uri => "/build/" . $evals->[0]->{builds}->[0] })->content());
ok($build->{job} eq "job", "The build's job name is job");
ok($build->{finished} == 0, "The build isn't finished yet");
ok($build->{build_outputs}->{out}->{path} =~ /^\/nix\/store\/[a-zA-Z0-9]{32}-job$/, "The build's outpath is in the Nix store and named 'job'");

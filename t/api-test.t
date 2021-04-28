use strict;
use Setup;
use JSON;
use File::Copy;

my %ctx = test_init(
    hydra_config => q|
# No caching for PathInput plugin, otherwise we get wrong values
# (as it has a 30s window where no changes to the file are considered).
path_input_cache_validity_seconds = 0
|
);


my $jobsetdir = $ctx{tmpdir} . '/jobset';
mkdir($jobsetdir);
copy($ctx{jobsdir} . '/api-test.nix', "$jobsetdir/default.nix");

require Hydra::Schema;
use HTTP::Request::Common;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

{
    my $user = $db->resultset('Users')->find({ username => 'root' });
    $user->setPassword('foobar');
    $user->userroles->update_or_create({ role => 'admin' });
}

my $cookie = "";

sub request_json {
    my ($opts) = @_;
    my $req = HTTP::Request->new;
    $req->method($opts->{method} or "GET");
    $req->uri("http://localhost$opts->{uri}");
    $req->header(Accept => "application/json");
    $req->header(Content_Type => "application/json");
    $req->header(Origin => "http://localhost/") if $opts->{method} eq "POST";
    $req->header(Cookie => $cookie);

    $req->content(encode_json($opts->{data})) if defined $opts->{data};
    my $res = request($req);
    print $res->as_string();
    return $res;
}

my $result = request_json({ uri => "/login", method => "POST", data => { username => "root", password => "wrong" } });
ok($result->code() == 403, "Incorrect password rejected.");

my $result = request_json({ uri => "/login", method => "POST", data => { username => "root", password => "foobar" } });

my $user = decode_json($result->content());

ok($user->{username} eq "root", "The root user is named root");
ok($user->{userroles}->[0] eq "admin", "The root user is an admin");
$cookie = $result->header("set-cookie");

$user = decode_json(request_json({ uri => "/current-user" })->content());
ok($user->{username} eq "root", "The current user is named root");
ok($user->{userroles}->[0] eq "admin", "The current user is an admin");

ok(request_json({ uri => '/project/sample' })->code() == 404, "Non-existent projects don't exist");

$result = request_json({ uri => '/project/sample', method => 'PUT', data => { displayname => "Sample", enabled => "1", visible => "1", } });
ok($result->code() == 201, "PUTting a new project creates it");

my $project = decode_json(request_json({ uri => '/project/sample' })->content());

ok((not @{$project->{jobsets}}), "A new project has no jobsets");

$result = request_json({ uri => '/jobset/sample/default', method => 'PUT', data => { nixexprpath => "default.nix", nixexprinput => "my-src", inputs => { "my-src" => { type => "path", value => $jobsetdir } }, enabled => "1", visible => "1", checkinterval => "3600"} });
ok($result->code() == 201, "PUTting a new jobset creates it");

my $jobset = decode_json(request_json({ uri => '/jobset/sample/default' })->content());

ok(exists $jobset->{jobsetinputs}->{"my-src"}, "The new jobset has a 'my-src' input");

ok($jobset->{jobsetinputs}->{"my-src"}->{"jobsetinputalts"}->[0] eq $jobsetdir, "The 'my-src' input is in $jobsetdir");

ok(evalSucceeds($db->resultset('Jobsets')->find({ name => 'default' })), "Evaluating should exit with return code 0");

$result = request_json({ uri => '/jobset/sample/default/evals' });
ok($result->code() == 200, "Can get evals of a jobset");
my $evals = decode_json($result->content())->{evals};
my $eval = $evals->[0];
ok($eval->{hasnewbuilds} == 1, "The first eval of a jobset has new builds");


open(my $fh, ">>", "${jobsetdir}/default.nix") or die "didn't open?";
say $fh "\n";
close $fh;
ok(evalSucceeds($db->resultset('Jobsets')->find({ name => 'default' })), "Evaluating should exit with return code 0");

my $evals = decode_json(request_json({ uri => '/jobset/sample/default/evals' })->content())->{evals};
ok(scalar(@$evals) == 2, "Changing a jobset source creates the second evaluation");
ok($evals->[0]->{jobsetevalinputs}->{"my-src"}->{revision} != $evals->[1]->{jobsetevalinputs}->{"my-src"}->{revision}, "Changing a jobset source changes its revision");

my $build = decode_json(request_json({ uri => "/build/" . $evals->[0]->{builds}->[0] })->content());
ok($build->{job} eq "job", "The build's job name is job");
ok($build->{finished} == 0, "The build isn't finished yet");
ok($build->{buildoutputs}->{out}->{path} =~ /\/nix\/store\/[a-zA-Z0-9]{32}-job$/, "The build's outpath is in the Nix store and named 'job'");


my $search_project = decode_json(request_json({ uri => "/search/?query=sample" })->content());
ok($search_project->{projects}[0]->{name} == "sample", "Search for project 'sample' works");

my $search_build = decode_json(request_json({ uri => "/search/?query=" . $build->{buildoutputs}->{out}->{path} })->content());
ok($search_build->{builds}[0]->{buildoutputs}->{out}->{path} == $build->{buildoutputs}->{out}->{path}, "Search for builds work");

done_testing;
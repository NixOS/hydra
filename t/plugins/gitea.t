use feature 'unicode_strings';
use strict;
use warnings;
use JSON;
use Setup;

my %ctx = test_init(
    hydra_config => q|
    <gitea_authorization>
    root=d7f16a3412e01a43a414535b16007c6931d3a9c7
    </gitea_authorization>
|);

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $scratch = "$ctx{tmpdir}/scratch";
mkdir $scratch;

my $uri = "file://$scratch/git-repo";

my $jobset = createJobsetWithOneInput('gitea', 'git-input.nix', 'src', 'git', $uri, $ctx{jobsdir});

sub addStringInput {
    my ($jobset, $name, $value) = @_;
    my $input = $jobset->jobsetinputs->create({name => $name, type => "string"});
    $input->jobsetinputalts->create({value => $value, altnr => 0});
}

addStringInput($jobset, "gitea_repo_owner", "root");
addStringInput($jobset, "gitea_repo_name", "foo");
addStringInput($jobset, "gitea_status_repo", "src");
addStringInput($jobset, "gitea_http_url", "http://localhost:8282/gitea");

updateRepository('gitea', "$ctx{testdir}/jobs/git-update.sh", $scratch);

ok(evalSucceeds($jobset), "Evaluating nix expression");
is(nrQueuedBuildsForJobset($jobset), 1, "Evaluating jobs/runcommand.nix should result in 1 build1");

(my $build) = queuedBuildsForJobset($jobset);
ok(runBuild($build), "Build should succeed with exit code 0");

my $filename = $ENV{'HYDRA_DATA'} . "/giteaout.json";
my $pid;
if (!defined($pid = fork())) {
    die "Cannot fork(): $!";
} elsif ($pid == 0) {
    exec("python3 $ctx{jobsdir}/server.py $filename");
} else {
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build should be finished.");
    is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");
    ok(sendNotifications(), "Sent notifications");

    kill('INT', $pid);
}

open(my $fh, "<", $filename) or die ("Can't open(): $!\n");
my $i = 0;
my $uri = <$fh>;
my $data = <$fh>;

ok(index($uri, "gitea/api/v1/repos/root/foo/statuses") != -1, "Correct URL");

my $json = JSON->new;
my $content;
$content = $json->decode($data);

is($content->{state}, "success", "Success notification");

done_testing;

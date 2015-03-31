use strict;
use File::Basename;
use File::Copy;
use Hydra::Model::DB;
use Hydra::Helper::Nix;
use Nix::Store;
use Cwd;

my $db = Hydra::Model::DB->new;

use Test::Simple tests => 10;

$db->resultset('Users')->create({
    username => "root",
    emailaddress => 'root@invalid.org',
    password => ''
});

my $project = $db->resultset('Projects')->create({
    name => "tests",
    displayname => "",
    owner => "root"
});

my $jobset = $project->jobsets->create({
    name => "basic",
    nixexprinput => "jobs",
    nixexprpath => "default.nix",
    channelattr => "channel",
    emailoverride => ""
});

my $jobsetInput = $jobset->jobsetinputs->create({
    name => "jobs",
    type => "path"
});

$jobsetInput->jobsetinputalts->create({
    altnr => 0,
    value => "/tmp/jobs"
});

my $channelUrl = "http://localhost:3000/jobset/tests/basic/channel/latest";
my $channelPath = "/nix/var/nix/profiles/per-user/hydra/channels/test";

sub rebuild {
    system("hydra-evaluator " . $jobset->project->name . " " . $jobset->name);
    my $success = 1;
    foreach my $build ($jobset->builds->search({finished => 0})) {
        system("hydra-build " . $build->id);

        my $result = $db->resultset('Builds')->find($build->id)->buildstatus;

        print "result: ".$result."\n";

        if ($build->job->name eq "failedJob") {
            ok($result != 0, "expect failedJob to fail");
        } else {
            $success = $result == 0 ? $success : 0;
        }
    }
    return $success;
}

sub exprContent {
    open my $chanExpr, '<', "$channelPath/default.nix";
    local $/;
    my $content = <$chanExpr>;
    close $chanExpr;
    return $content;
}

ok(rebuild, "rebuild succeeded");

system("nix-channel --add $channelUrl test");
system("nix-channel --update");

ok(-e "$channelPath/default.nix", "channel expression file existing");

ok(exprContent eq "\"magic\"\n", "expression content is valid");

system("sed -i -e 's/#OVERRIDE#.*/exit 1/' /tmp/jobs/default.nix");

ok(!rebuild, "rebuild failed");

system("nix-channel --update");

ok(exprContent eq "\"magic\"\n", "expression content is still valid");

system("sed -i -e '/exit 1/d' -e 's/\"magic\"/42/' /tmp/jobs/default.nix");

ok(rebuild, "rebuild succeeded");

system("nix-channel --update");

ok(exprContent eq "42\n", "new expression content has arrived");

my $unrelatedProject = $db->resultset('Projects')->create({
    name => "unrelated",
    displayname => "",
    owner => "root"
});

my $unrelatedJobset = $unrelatedProject->jobsets->create({
    name => "basic",
    nixexprinput => "jobs",
    nixexprpath => "default.nix",
    channelattr => "channel",
    emailoverride => ""
});

my $unrelatedJobsetInput = $unrelatedJobset->jobsetinputs->create({
    name => "jobs",
    type => "path"
});

mkdir "/tmp/jobs2";
copy("/tmp/jobs/default.nix", "/tmp/jobs2/default.nix");
system("sed -i -e 's/42/666/' /tmp/jobs2/default.nix");

$unrelatedJobsetInput->jobsetinputalts->create({
    altnr => 0,
    value => "/tmp/jobs2"
});

ok(rebuild, "rebuild succeeded");

system("nix-channel --update");

ok(exprContent eq "42\n", "it's still the same expression content");

use strict;
use warnings;
use File::Basename;
use Hydra::Model::DB;
use Hydra::Helper::Nix;
use Nix::Store;
use Cwd;

my $db = Hydra::Model::DB->new;

use Test::Simple tests => 6;

$db->resultset('Users')->create({ username => "root", emailaddress => 'root@invalid.org', password => '' });

$db->resultset('Projects')->create({ name => "tests", displayname => "", owner => "root" });
my $project = $db->resultset('Projects')->update_or_create({ name => "tests", displayname => "", owner => "root" });
my $jobset  = $project->jobsets->create(
    { name => "basic", nixexprinput => "jobs", nixexprpath => "default.nix", emailoverride => "" });

my $jobsetinput;

$jobsetinput = $jobset->jobsetinputs->create({ name => "jobs", type => "path" });
$jobsetinput->jobsetinputalts->create({ altnr => 0, value => getcwd . "/jobs" });
system("hydra-eval-jobset " . $jobset->project->name . " " . $jobset->name);

my $successful_hash;
foreach my $build ($jobset->builds->search({ finished => 0 })) {
    system("hydra-build " . $build->id);
    my @outputs = $build->buildoutputs->all;
    my $hash    = substr basename($outputs[0]->path), 0, 32;
    if ($build->job->name eq "job") {
        ok(-e "/tmp/s3/hydra/$hash.nar",     "The nar of a successful matched build is uploaded");
        ok(-e "/tmp/s3/hydra/$hash.narinfo", "The narinfo of a successful matched build is uploaded");
        $successful_hash = $hash;
    }
}

system("hydra-s3-backup-collect-garbage");
ok(-e "/tmp/s3/hydra/$successful_hash.nar",     "The nar of a build that's a root is not removed by gc");
ok(-e "/tmp/s3/hydra/$successful_hash.narinfo", "The narinfo of a build that's a root is not removed by gc");

my $gcRootsDir = getGCRootsDir;
opendir my $dir, $gcRootsDir or die;
while (my $file = readdir $dir) {
    next if $file eq "." or $file eq "..";
    unlink "$gcRootsDir/$file";
}
closedir $dir;
system("hydra-s3-backup-collect-garbage");
ok(not -e "/tmp/s3/hydra/$successful_hash.nar",     "The nar of a build that's not a root is removed by gc");
ok(not -e "/tmp/s3/hydra/$successful_hash.narinfo", "The narinfo of a build that's not a root is removed by gc");

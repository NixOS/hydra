use feature 'unicode_strings';
use strict;
use Setup;
use IO::Uncompress::Bunzip2 qw(bunzip2);
use Archive::Tar;
use JSON qw(decode_json);
use Data::Dumper;
my %ctx = test_init(
  use_external_destination_store => 0
);

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

# Most basic test case, no parameters
my $jobset = createBaseJobset("nested-attributes", "nested-attributes.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset));
is(nrQueuedBuildsForJobset($jobset), 4);

for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' should exit with code 0");
    my $newbuild = $db->resultset('Builds')->find($build->id);
    is($newbuild->finished, 1, "Build '".$build->job."' should be finished.");
    is($newbuild->buildstatus, 0, "Build '".$build->job."' should have buildstatus 0.");
}

my $compressed = get('/jobset/tests/nested-attributes/channel/latest/nixexprs.tar.bz2');
my $tarcontent;
bunzip2(\$compressed => \$tarcontent);
open(my $tarfh, "<", \$tarcontent);
my $tar = Archive::Tar->new($tarfh);

my $defaultnix = $ctx{"tmpdir"} . "/channel-default.nix";
$tar->extract_file("channel/default.nix", $defaultnix);

print STDERR $tar->get_content("channel/default.nix");

(my $status, my $stdout, my $stderr) = Hydra::Helper::Nix::captureStdoutStderr(5, "nix-env", "--json", "--query", "--available", "--attr-path", "--file", $defaultnix);
is($stderr, "", "Stderr should be empty");
is($status, 0, "Querying the packages should succeed");

my $packages = decode_json($stdout);
my $keys = [sort keys %$packages];
is($keys, [
    "packageset-nested",
    "packageset.deeper.deeper.nested",
    "packageset.nested",
    "packageset.nested2",
]);
is($packages->{"packageset-nested"}->{"name"}, "actually-top-level");
is($packages->{"packageset.nested"}->{"name"}, "actually-nested");

done_testing;

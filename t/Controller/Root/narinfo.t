use strict;
use warnings;
use Setup;
use Data::Dumper;
use JSON qw(decode_json);
my %ctx = test_init(
  # Without this, the test will fail because a `file:` store is not treated as a
  # local store by `isLocalStore` in src/lib/Hydra/Helper/Nix.pm, and any
  # requests to /HASH.narinfo will fail.
  use_external_destination_store => 0
);

require Hydra::Schema;
require Hydra::Model::DB;
require Hydra::Helper::Nix;

use Test2::V0;
require Catalyst::Test;
use HTTP::Request::Common;
Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("basic", "basic.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating jobs/basic.nix should exit with return code 0");
for my $build (queuedBuildsForJobset($jobset)) {
    ok(runBuild($build), "Build '".$build->job."' from jobs/basic.nix should exit with return code 0");
}

subtest "/HASH.narinfo" => sub {
    my $build_redirect = request(GET '/job/tests/basic/empty_dir/latest-finished');
    my $url = URI->new($build_redirect->header('location'))->path;
    my $json = request(GET $url, Accept => 'application/json');
    my $data = decode_json($json->content);
    my $outpath = $data->{buildoutputs}{out}{path};
    my ($hash) = $outpath =~ qr{/nix/store/([a-z0-9]{32}).*};
    my $narinfo_response = request(GET "/$hash.narinfo");
    ok($narinfo_response->is_success, "Getting the narinfo of a build");

    my ($storepath) = $narinfo_response->content =~ qr{StorePath: (.*)};
    is($storepath, $outpath, "The returned store path is the same as the out path")
};

done_testing;

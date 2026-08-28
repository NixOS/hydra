use strict;
use warnings;
use Setup;
use Data::Dumper;
use JSON::MaybeXS qw(decode_json);
my %ctx = test_init(
  # Without this, the test will fail because a `file:` store is not treated as a
  # local store by `isLocalStore` in src/lib/Hydra/Helper/Nix.pm, and any
  # requests to /HASH.narinfo will fail.
  use_external_destination_store => 0
);

use Test2::V0;
use HTTP::Request::Common;
setup_catalyst_test($ctx{context});

require Hydra::Schema;
require Hydra::Helper::Nix;

my $db = $ctx{context}->db();

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset($db, "basic", "basic.nix", $ctx{jobsdir});

ok(evalSucceeds($ctx{context}, $jobset), "Evaluating jobs/basic.nix should exit with return code 0");
my @builds = queuedBuildsForJobset($jobset);
ok(runBuilds($ctx{context}, @builds), "Building jobs/basic.nix should exit with return code 0");

subtest "/HASH.narinfo" => sub {
    my $build_redirect = request(GET '/job/tests/basic/empty_dir/latest-finished');
    my $url = URI->new($build_redirect->header('location'))->path;
    my $json = request(GET $url, Accept => 'application/json');
    my $data = decode_json($json->content);
    my $outpath = $data->{buildoutputs}{out}{path};
    my ($hash) = $outpath =~ qr{/nix/store/([a-z0-9]{32}).*};
    my $narinfo_response = request(GET "/$hash.narinfo");
    ok($narinfo_response->is_success, "Getting the narinfo of a build");

    my $narinfo = $narinfo_response->content;

    my ($storepath) = $narinfo =~ qr{StorePath: (.*)};
    is($storepath, $outpath, "The returned store path is the same as the out path");

    # Which of these fields carry a full path and which carry a bare
    # `<hash>-<name>` is fixed by the narinfo format, and getting it wrong is
    # not something the field above would catch: a bare store path in
    # `StorePath`, or a full path in `References`, still parses.
    my ($url) = $narinfo =~ qr{URL: (.*)};
    like($url, qr{^nar/[a-z0-9]{32}-}, "URL names the NAR by bare store path");

    my ($references) = $narinfo =~ qr{References: (.*)};
    for my $reference (split(" ", $references // "")) {
        unlike($reference, qr{/}, "Reference '$reference' is a bare store path");
    }

    if (my ($deriver) = $narinfo =~ qr{Deriver: (.*)}) {
        unlike($deriver, qr{/}, "Deriver is a bare store path");
    }
};

done_testing;

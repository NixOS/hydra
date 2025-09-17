use strict;
use warnings;
use Setup;
use Test2::V0;
use Catalyst::Test ();
use HTTP::Request::Common;

my %ctx = test_init();

Catalyst::Test->import('Hydra');

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

# Create a simple Nix expression that uses the existing build-product-simple.sh
my $jobsdir = $ctx{jobsdir};
my $nixfile = "$jobsdir/simple.nix";
open(my $fh, '>', $nixfile) or die "Cannot create simple.nix: $!";
print $fh <<"EOF";
with import ./config.nix;
{
  simple = mkDerivation {
    name = "build-product-simple";
    builder = ./build-product-simple.sh;
  };
}
EOF
close($fh);

# Create a jobset that uses the simple build
my $jobset = createBaseJobset("simple", "simple.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating simple.nix should succeed");
is(nrQueuedBuildsForJobset($jobset), 1, "Should have 1 build queued");

my $build = (queuedBuildsForJobset($jobset))[0];
ok(runBuild($build), "Build should succeed");

$build->discard_changes();

subtest "Test downloading build products (regression test for #1520)" => sub {
    # Get the build URL
    my $build_id = $build->id;

    # First, check that the build has products
    my @products = $build->buildproducts;
    ok(scalar @products >= 1, "Build should have at least 1 product");

    # Find the doc product (created by build-product-simple.sh)
    my ($doc_product) = grep { $_->type eq "doc" } @products;
    ok($doc_product, "Should have a doc product");

    if ($doc_product) {
        # Test downloading via the download endpoint
        # This tests the serveFile function which was broken in #1520
        my $download_url = "/build/$build_id/download/" . $doc_product->productnr . "/text.txt";
        my $response = request(GET $download_url);

        # The key test: should not return 500 error with "Can't use string ("1") as a HASH ref"
        isnt($response->code, 500, "Download should not return 500 error (regression test for #1520)");
        is($response->code, 200, "Download should succeed with 200")
            or diag("Response code: " . $response->code);

        like($response->header('Content-Security-Policy') // '', qr/\bsandbox\b/, 'CSP header present with sandbox');
        ok($response->header('Content-Length'), "Content-Length header should be present");
        is($response->header('Content-Type'), "text/plain", "Content-Type header should be text/plain");
        like($response->header('Content-Disposition'), qr/^attachment; filename="text.txt"$/, "Content-Disposition header should be correct");
    }
};

done_testing();

use feature 'unicode_strings';
use strict;
use warnings;
use JSON;
use Setup;

my %ctx = test_init(
    hydra_config => q|
    <runcommand>
      command = cp "$HYDRA_JSON" "$HYDRA_DATA/joboutput.json"
    </runcommand>
|);

require Hydra::Schema;
require Hydra::Model::DB;

use Test2::V0;

my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

# Most basic test case, no parameters
my $jobset = createBaseJobset("basic", "runcommand.nix", $ctx{jobsdir});

ok(evalSucceeds($jobset), "Evaluating jobs/runcommand.nix should exit with return code 0");
is(nrQueuedBuildsForJobset($jobset), 1, "Evaluating jobs/runcommand.nix should result in 1 build1");

(my $build) = queuedBuildsForJobset($jobset);

is($build->job, "metrics", "The only job should be metrics");
ok(runBuild($build), "Build should exit with return code 0");
my $newbuild = $db->resultset('Builds')->find($build->id);
is($newbuild->finished, 1, "Build should be finished.");
is($newbuild->buildstatus, 0, "Build should have buildstatus 0.");

ok(sendNotifications(), "Notifications execute successfully.");

my $dat = do {
    my $filename = $ENV{'HYDRA_DATA'} . "/joboutput.json";
    open(my $json_fh, "<", $filename)
        or die("Can't open \$filename\": $!\n");
    local $/;
    my $json = JSON->new;
    $json->decode(<$json_fh>)
};

subtest "Validate the top level fields match" => sub {
    is($dat->{build}, $newbuild->id, "The build event matches our expected ID.");
    is($dat->{buildStatus}, 0, "The build status matches.");
    is($dat->{event}, "buildFinished", "The build event matches.");
    is($dat->{finished}, JSON::true, "The build finished.");
    is($dat->{project}, "tests", "The project matches.");
    is($dat->{jobset}, "basic", "The jobset matches.");
    is($dat->{job}, "metrics", "The job matches.");
    is($dat->{nixName}, "my-build-product", "The nixName matches.");
    is($dat->{system}, $newbuild->system, "The system matches.");
    is($dat->{drvPath}, $newbuild->drvpath, "The derivation path matches.");
    is($dat->{timestamp}, $newbuild->timestamp, "The result has a timestamp field.");
    is($dat->{startTime}, $newbuild->starttime, "The result has a startTime field.");
    is($dat->{stopTime}, $newbuild->stoptime, "The result has a stopTime field.");
    is($dat->{homepage}, "https://github.com/NixOS/hydra", "The homepage is passed.");
    is($dat->{description}, "An example meta property.", "The description is passed.");
    is($dat->{license}, "GPL", "The license is passed.");
};

subtest "Validate the outputs match" => sub {
    is(scalar(@{$dat->{outputs}}), 2, "There are exactly two outputs");

    subtest "output: out" => sub {
        my ($output) = grep { $_->{name} eq "out" } @{$dat->{outputs}};
        my $expectedoutput = $newbuild->buildoutputs->find({name => "out"});

        is($output->{name}, "out", "Output is named corrrectly");
        is($output->{path}, $expectedoutput->path, "The output path matches the database's path.");
    };

    subtest "output: bin" => sub {
        my ($output) = grep { $_->{name} eq "bin" } @{$dat->{outputs}};
        my $expectedoutput = $newbuild->buildoutputs->find({name => "bin"});

        is($output->{name}, "bin", "Output is named corrrectly");
        is($output->{path}, $expectedoutput->path, "The output path matches the database's path.");
    };
};

subtest "Validate the metrics match" => sub {
    is(scalar(@{$dat->{metrics}}), 2, "There are exactly two metrics");

    my ($lineCoverage)  = grep { $_->{name} eq "lineCoverage" } @{$dat->{metrics}};
    my ($maxResident) = grep { $_->{name} eq "maxResident" } @{$dat->{metrics}};

    subtest "verifying the lineCoverage metric" => sub {
        is($lineCoverage->{name}, "lineCoverage", "The name matches.");
        is($lineCoverage->{value}, 18, "The value matches.");
        is($lineCoverage->{unit}, "%", "The unit matches.");
    };

    subtest "verifying the maxResident metric" => sub {
        is($maxResident->{name}, "maxResident", "The name matches.");
        is($maxResident->{value}, 27, "The value matches.");
        is($maxResident->{unit}, "KiB", "The unit matches.");
    };
};

subtest "Validate the products match" => sub {
    is(scalar(@{$dat->{outputs}}), 2, "There are exactly two outputs");

    subtest "product: out" => sub {
        my ($product) = grep { $_->{name} eq "my-build-product" } @{$dat->{products}};
        my $expectedproduct = $newbuild->buildproducts->find({name => "my-build-product"});

        is($product->{name}, "my-build-product", "The build product is named correctly.");
        is($product->{subtype}, "", "The subtype is empty.");
        is($product->{productNr}, $expectedproduct->productnr, "The product number matches.");
        is($product->{defaultPath}, "", "The default path matches.");
        is($product->{path}, $expectedproduct->path, "The path matches the output.");
        is($product->{fileSize}, undef, "The fileSize is undefined for the nix-build output type.");
        is($product->{sha256hash}, undef, "The sha256hash is undefined for the nix-build output type.");
    };

    subtest "output: bin" => sub {
        my ($product) = grep { $_->{name} eq "my-build-product-bin" } @{$dat->{products}};
        my $expectedproduct = $newbuild->buildproducts->find({name => "my-build-product-bin"});

        is($product->{name}, "my-build-product-bin", "The build product is named correctly.");
        is($product->{subtype}, "bin", "The subtype matches the output name");
        is($product->{productNr}, $expectedproduct->productnr, "The product number matches.");
        is($product->{defaultPath}, "", "The default path matches.");
        is($product->{path}, $expectedproduct->path, "The path matches the output.");
        is($product->{fileSize}, undef, "The fileSize is undefined for the nix-build output type.");
        is($product->{sha256hash}, undef, "The sha256hash is undefined for the nix-build output type.");
    };
};

done_testing;

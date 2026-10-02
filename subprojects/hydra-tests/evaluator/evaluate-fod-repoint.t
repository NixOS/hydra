use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();
my $db = $ctx->db();

my $jobset = $ctx->makeJobset(expression => "fod-repoint.nix")->{jobset};
my $variant = $jobset->jobsetinputs->create({name => "variant", type => "string"});
my $variantAlt = $variant->jobsetinputalts->create({altnr => 0, value => "a"});

ok(evalSucceeds($ctx, $jobset), "First evaluation succeeds");
my ($build) = queuedBuildsForJobset($jobset);
my $firstDrvPath = $build->get_column('drvpath');

$variantAlt->update({value => "b"});
ok(evalSucceeds($ctx, $jobset), "Second evaluation succeeds");
is(nrBuildsForJobset($jobset), 1, "The second evaluation reuses the build");

$build->discard_changes;
my $drvPath = $build->get_column('drvpath');
isnt($drvPath, $firstDrvPath, "The build points at the new derivation");
like($drvPath, qr{^\Q${\$db->storeDir}\E/}, "drvpath is stored with the store directory");

done_testing;

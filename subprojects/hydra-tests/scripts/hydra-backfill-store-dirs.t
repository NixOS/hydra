use strict;
use warnings;
use Setup;
use Test2::V0;

my $ctx = test_context();
my $db = $ctx->db();
my $dbh = $db->storage->dbh;
my $storeDir = $db->storeDir;

my $builds = $ctx->makeAndEvaluateJobset(expression => "one-job.nix");
my $build = $builds->{"one_job"};
my $buildId = $build->id;
my $evalId = $build->jobsetevals->first->id;
my $outPath = $build->buildoutputs->first->path->to_string;

# Put the rows the evaluation wrote back into the format of a deployment
# from before schema version 89: full paths and a null storeDir.
$dbh->do("UPDATE Builds SET drvPath = storeDir || '/' || drvPath, storeDir = NULL");
$dbh->do("UPDATE BuildOutputs SET path = storeDir || '/' || path, storeDir = NULL");
$dbh->do("UPDATE JobsetEvalInputs SET path = storeDir || '/' || path, storeDir = NULL WHERE path <> ''");

# A build product naming something *inside* its store path, which has to
# be split three ways rather than at the last slash.
$dbh->do(
    "INSERT INTO BuildProducts (build, productnr, type, subtype, path, name, defaultPath)
     VALUES (?, 1, 'doc', 'manual', ?, 'manual', 'index.html')",
    undef, $buildId, "$storeDir/$outPath/share/doc/manual");

# An output with no path yet, as a content-addressed one has until it is
# built. It sorts with the build's other rows, so it is under the cursor
# the whole time.
$dbh->do("INSERT INTO BuildOutputs (build, name, path) VALUES (?, 'unbuilt', NULL)",
    undef, $buildId);

# An input with no store path, which `hydra-eval-jobset` writes as "".
$dbh->do(
    "INSERT INTO JobsetEvalInputs (eval, name, altNr, type, value, path)
     VALUES (?, 'flag', 0, 'boolean', 'true', '')",
    undef, $evalId);

my ($res, $stdout, $stderr) = $ctx->capture_cmd(60, "hydra-backfill-store-dirs");
is($res, 0, "hydra-backfill-store-dirs exits zero, rather than looping forever")
    or diag("stdout: $stdout\nstderr: $stderr");

sub row {
    my ($sql, @bind) = @_;
    return $dbh->selectrow_hashref($sql, undef, @bind);
}

is(row("SELECT drvPath, storeDir FROM Builds WHERE id = ?", $buildId)->{storedir},
    $storeDir, "Builds rows get their store dir");
unlike(row("SELECT drvPath FROM Builds WHERE id = ?", $buildId)->{drvpath},
    qr{/}, "and keep only the basename");

is(row("SELECT path, subPath, storeDir FROM BuildProducts WHERE build = ?", $buildId),
    { path => $outPath, subpath => "share/doc/manual", storedir => $storeDir },
    "A product inside a store path is split into store dir, store path and sub-path");

is(row("SELECT path, storeDir FROM BuildOutputs WHERE build = ? AND name = 'unbuilt'", $buildId),
    { path => undef, storedir => undef },
    "An output with no path is left as it is");

is(row("SELECT path, storeDir FROM JobsetEvalInputs WHERE eval = ? AND name = 'flag'", $evalId),
    { path => "", storedir => $storeDir },
    "An input with no store path gets the store dir, as Hydra writes new ones");

# What schema version 90 checks before it will run.
for my $table (qw(Builds BuildSteps BuildOutputs BuildStepOutputs BuildInputs
                  JobsetEvalInputs BuildProducts FailedPaths)) {
    my $col = $table =~ /^Build(s|Steps)$/ ? "drvPath" : "path";
    my ($pending) = $dbh->selectrow_array(
        "SELECT count(*) FROM $table WHERE storeDir IS NULL AND $col IS NOT NULL");
    is($pending, 0, "$table has nothing left to convert");
}

done_testing;

#! @perl@ -w

use strict;
use XML::Simple;
use DBI;
use File::Basename;


my $jobsFile = "../test.nix";


my $dbh = DBI->connect("dbi:SQLite:dbname=hydra.sqlite", "", "");


my $jobsXml = `nix-env -f $jobsFile --query --available "*" --attr-path --out-path --drv-path --meta --xml --system-filter "*"`
    or die "cannot evaluate the Nix expression containing the job definitions: $?";

print "$jobsXml";


my $jobs = XMLin($jobsXml, KeyAttr => ['attrPath', 'name'])
    or die "cannot parse XML output";


foreach my $jobName (keys %{$jobs->{item}}) {
    my $job = $jobs->{item}->{$jobName};
    my $description = defined $job->{meta}->{description} ? $job->{meta}->{description}->{value} : "";
    print "JOB: $jobName ($description)\n";

    my $outPath = $job->{outPath};
    my $drvPath = $job->{drvPath};

    if (scalar(@{$dbh->selectall_arrayref("select * from builds where name = ? and outPath = ?", {}, $jobName, $outPath)}) > 0) {
        print "  already done\n";
        next;
    }

    my $res = system("nix-build $jobsFile --attr $jobName");

    my $buildStatus = $res == 0 ? 0 : 1;

    $dbh->begin_work;

    $dbh->prepare("insert into builds(timestamp, name, description, drvPath, outPath, buildStatus) values(?, ?, ?, ?, ?, ?)")
        ->execute(time(), $jobName, $description, $drvPath, $outPath, $buildStatus);
    
    my $buildId = $dbh->last_insert_id(undef, undef, undef, undef);
    print "  db id = $buildId\n";

    if ($buildStatus == 0) {

        $dbh->prepare("insert into buildProducts(buildId, type, subtype, path) values(?, ?, ?, ?)")
            ->execute($buildId, "nix-build", "", $outPath);
        
        my $logPath = "/nix/var/log/nix/drvs/" . basename $drvPath;
        if (-e $logPath) {
            print "  LOG $logPath\n";
            $dbh->prepare("insert into buildLogs(buildId, logPhase, path, type) values(?, ?, ?, ?)")
                ->execute($buildId, "full", $logPath, "raw");
        }

        if (-e "$outPath/log") {
            foreach my $logPath (glob "$outPath/log/*") {
                print "  LOG $logPath\n";
                $dbh->prepare("insert into buildLogs(buildId, logPhase, path, type) values(?, ?, ?, ?)")
                    ->execute($buildId, basename($logPath), $logPath, "raw");
            }
        }
    }

    $dbh->commit;
}

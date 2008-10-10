#! @perl@ -w

use strict;
use XML::Simple;
use DBI;


my $dbh = DBI->connect("dbi:SQLite:dbname=hydra.sqlite", "", "");


my $jobsXml = `nix-env -f ../test.nix --query --available "*" --attr-path --out-path --drv-path --meta --xml --system-filter "*"`
    or die "cannot evaluate the Nix expression containing the job definitions: $?";

print "$jobsXml";


my $jobs = XMLin($jobsXml, KeyAttr => ['attrPath', 'name'])
    or die "cannot parse XML output";


foreach my $jobName (keys %{$jobs->{item}}) {
    my $job = $jobs->{item}->{$jobName};
    print "JOB: $jobName ($job->{meta}->{description}->{value})\n";

    my $outPath = $job->{outPath};

    if (scalar(@{$dbh->selectall_arrayref("select * from builds where name = ? and outPath = ?", {}, $jobName, $outPath)}) > 0) {
        print "  already done\n";
        next;
    }

    my $res = system("nix-build ../test.nix --attr $jobName");

    my $buildStatus = $res == 0 ? 0 : 1;

    $dbh->prepare("insert into builds(timestamp, name, description, drvPath, outPath, buildStatus) values(?, ?, ?, ?, ?, ?)")
        ->execute(time(), $jobName, $job->{meta}->{description}->{value}, $job->{drvPath}, $outPath, $buildStatus);
    print "  db id = ", $dbh->last_insert_id(undef, undef, undef, undef), "\n";
}

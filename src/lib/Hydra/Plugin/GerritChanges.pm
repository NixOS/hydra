# This plugin allows to build gerrit changes.
#
# The declarative project spec.json file must contains an input such as
#   "pulls": {
#      "type": "gerritchanges",
#      "value": "your.gerrit.server gerrit-query-options",
#      "emailresponsible": false
#   }
# The gerrit-query-options are passed verbose to the "gerrit query" command
# This could be used to only select changes for a single project: "project:tools/gerrit".

package Hydra::Plugin::GerritChanges;

use strict;
use parent 'Hydra::Plugin';
use Hydra::Helper::CatalystUtils;
use File::Temp;
use POSIX qw(strftime);
use Net::SSH::Perl;

sub supportedInputTypes {
    my ($self, $inputTypes) = @_;
    $inputTypes->{'gerritchanges'} = 'Open Gerrit Changes';
}

sub fetchInput {
    my ($self, $type, $name, $value, $project, $jobset) = @_;
    return undef if $type ne "gerritchanges";

    (my $server, my @options) = split ' ', $value;
    my $cmd;
    if (@options){
        $cmd = "gerrit query --current-patch-set status:open @options --format=JSON"
    } else {
        $cmd = "gerrit query --current-patch-set status:open --format=JSON"
    }
    my $ssh = Net::SSH::Perl->new($server);
    $ssh->login();
    my($stdout, $stderr, $exit) = $ssh->cmd($cmd);
    die "Error fetching gerrit changes: $stderr\n"
        unless $exit == 0;

    my $tempdir = File::Temp->newdir("gerrit-changes" . "XXXXX", TMPDIR => 1);
    my $filename = "$tempdir/gerrit-changes-unprocessed.json";
    open(my $fh, ">", $filename) or die "Cannot open $filename for writing: $!";
    print $fh $stdout;
    close $fh;
    system("jq --slurp --compact-output 'map(select(.type != \"stats\"))' < $filename > $tempdir/gerrit-changes.json");
    my $storePath = trim(`nix-store --add "$tempdir/gerrit-changes.json"`
        or die "cannot copy path $tempdir/gerrit-changes.json to the Nix store.\n");
    chomp $storePath;
    my $timestamp = time;
    return { storePath => $storePath, revision => strftime "%Y%m%d%H%M%S", gmtime($timestamp) };
}

1;

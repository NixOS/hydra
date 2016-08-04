package Setup;

use strict;
use Exporter;
use Hydra::Helper::Nix;
use Hydra::Model::DB;
use Hydra::Helper::AddBuilds;
use Cwd;

our @ISA = qw(Exporter);
our @EXPORT = qw(hydra_setup nrBuildsForJobset queuedBuildsForJobset nrQueuedBuildsForJobset createBaseJobset createJobsetWithOneInput evalSucceeds runBuild updateRepository);

sub hydra_setup {
    my ($db) = @_;
    $db->resultset('Users')->create({ username => "root", email_address => 'root@invalid.org', password => '' });
}

sub nrBuildsForJobset {
    my ($jobset) = @_;
    return $jobset->builds->search({},{})->count ;
}

sub queuedBuildsForJobset {
    my ($jobset) = @_;
    return $jobset->builds->search({finished => 0});
}

sub nrQueuedBuildsForJobset {
    my ($jobset) = @_;
    return queuedBuildsForJobset($jobset)->count ;
}

sub createBaseJobset {
    my ($jobsetName, $nixexprpath) = @_;

    my $db = Hydra::Model::DB->new;
    my $project = $db->resultset('Projects')->update_or_create({name => "tests", display_name => "", owner => "root"});
    my $jobset = $project->jobsets->create({name => $jobsetName, nix_expr_input => "jobs", nix_expr_path => $nixexprpath, email_override => ""});

    my $jobset_input;
    my $jobsetinputals;

    $jobset_input = $jobset->jobset_inputs->create({
        name => "jobs",
        type => "path",
        properties => { value => getcwd."/jobs" }
    });

    return $jobset;
}

sub createJobsetWithOneInput {
    my ($jobsetName, $nixexprpath, $name, $type, $props) = @_;
    my $jobset = createBaseJobset($jobsetName, $nixexprpath);

    my $jobset_input;
    my $jobsetinputals;

    $jobset_input = $jobset->jobset_inputs->create({
        name => $name,
        type => $type,
        properties => $props
    });

    return $jobset;
}

sub evalSucceeds {
    my ($jobset) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-evaluator", $jobset->project->name, $jobset->name));
    chomp $stdout; chomp $stderr;
    print STDERR "Evaluation errors for jobset ".$jobset->project->name.":".$jobset->name.": \n".$jobset->error_msg."\n" if $jobset->error_msg;
    print STDERR "STDOUT: $stdout\n" if $stdout ne "";
    print STDERR "STDERR: $stderr\n" if $stderr ne "";
    return !$res;
}

sub runBuild {
    my ($build) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ("hydra-queue-runner", "-vvvv", "--build-one", $build->id));
    return !$res;
}

sub updateRepository {
    my ($scm, $update) = @_;
    my ($res, $stdout, $stderr) = captureStdoutStderr(60, ($update, $scm));
    die "unexpected update error with $scm: $stderr\n" if $res;
    my ($message, $loop, $status) = $stdout =~ m/::(.*) -- (.*) -- (.*)::/;
    print STDOUT "Update $scm repository: $message\n";
    return ($loop eq "continue", $status eq "updated");
}

1;

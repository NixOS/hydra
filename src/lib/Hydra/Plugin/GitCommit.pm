package Hydra::Plugin::GitCommit;

use strict;
use parent 'Hydra::Plugin';
use Cwd;
use Hydra::Helper::CatalystUtils;
use autodie qw( system );

sub buildFinished {
    my ($self, $build, $dependents) = @_;
    return unless $build->buildstatus == 0;
    my $cfg = $self->{config}->{gitcommit};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    undef $cfg;
    my $jobName = showJobName $build;
    foreach my $c (@config) {
        if ($jobName =~ /^$c->{jobs}$/) {
            $cfg = $c;
            last;
        }
    }
    return unless defined $cfg;
    my $patch = ($build->buildoutputs)[0]->path . "/build-support/hydra-git-commit.patch";
    return unless -e $patch;
    my $tempdir = File::Temp->newdir("hydra-git-commit-" . $build->id . "-XXXXX", TMPDIR => 1);

    my $dir = getcwd;
    eval {
        system("git clone --depth 1 --branch $cfg->{branch} $cfg->{repo} $tempdir/checkout");
        chdir "$tempdir/checkout" or die;
        system("patch -Np1 -i $patch");
        system("git add .");
        my $id = $build->id;
        system("git config user.name \"Hydra git plugin\"");
        system("git config user.email \"<>\"");
        system("git commit -m \"Automated commit from hydra build $id\"");
        system("git config push.default simple");
        system("git push");
    };
    my $err = $@;
    chdir $dir;
    die $err if defined $err;
}

1;

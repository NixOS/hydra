package Hydra::Helper::AddBuilds;

use strict;
use utf8;
use Encode;
use JSON;
use Nix::Store;
use Nix::Config;
use Hydra::Model::DB;
use Hydra::Helper::Nix;
use Digest::SHA qw(sha256_hex);
use File::Basename;
use File::stat;
use File::Path;
use File::Temp;
use File::Spec;
use File::Slurp;
use Hydra::Helper::CatalystUtils;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    updateDeclarativeJobset
    handleDeclarativeJobsetBuild
);


sub updateDeclarativeJobset {
    my ($db, $project, $jobsetName, $declSpec) = @_;

    my @allowed_keys = qw(
        enabled
        hidden
        description
        nixexprinput
        nixexprpath
        checkinterval
        schedulingshares
        enableemail
        emailoverride
        keepnr
    );
    my %update = ( name => $jobsetName );
    foreach my $key (@allowed_keys) {
        $update{$key} = $declSpec->{$key};
        delete $declSpec->{$key};
    }
    txn_do($db, sub {
        my $jobset = $project->jobsets->update_or_create(\%update);
        $jobset->jobsetinputs->delete;
        while ((my $name, my $data) = each %{$declSpec->{"inputs"}}) {
            my $input = $jobset->jobsetinputs->create(
                { name => $name,
                  type => $data->{type},
                  emailresponsible => $data->{emailresponsible}
                });
            $input->jobsetinputalts->create({altnr => 0, value => $data->{value}});
        }
        delete $declSpec->{"inputs"};
        die "invalid keys ($declSpec) in declarative specification file\n" if (%{$declSpec});
    });
};


sub handleDeclarativeJobsetBuild {
    my ($db, $project, $build) = @_;

    eval {
        my $id = $build->id;
        die "Declarative jobset build $id failed" unless $build->buildstatus == 0;
        my $declPath = ($build->buildoutputs)[0]->path;
        my $declText = readNixFile($declPath)
            or die "Couldn't read declarative specification file $declPath: $!";
        my $declSpec = decode_json($declText);
        txn_do($db, sub {
            my @kept = keys %$declSpec;
            push @kept, ".jobsets";
            $project->jobsets->search({ name => { "not in" => \@kept } })->update({ enabled => 0, hidden => 1 });
            while ((my $jobsetName, my $spec) = each %$declSpec) {
                eval {
                    updateDeclarativeJobset($db, $project, $jobsetName, $spec);
                };
                if ($@) {
                    print STDERR "ERROR: failed to process declarative jobset ", $project->name, ":${jobsetName}, ", $@, "\n";
                }
            }
        });
    };
    $project->jobsets->find({ name => ".jobsets" })->update({ errormsg => $@, errortime => time, fetcherrormsg => undef })
        if defined $@;

};


1;

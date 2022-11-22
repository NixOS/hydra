package Hydra::Helper::AddBuilds;

use strict;
use warnings;
use utf8;
use Encode;
use JSON::MaybeXS;
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
use Hydra::Helper::CatalystUtils;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    validateDeclarativeJobset
    createJobsetInputsRowAndData
    updateDeclarativeJobset
    handleDeclarativeJobsetBuild
    handleDeclarativeJobsetJson
);


sub validateDeclarativeJobset {
    my ($config, $project, $jobsetName, $declSpec) = @_;

    my @allowed_keys = qw(
        enabled
        hidden
        type
        flake
        description
        nixexprinput
        nixexprpath
        checkinterval
        schedulingshares
        enableemail
        enable_dynamic_run_command
        emailoverride
        keepnr
    );
    my %update = ( name => $jobsetName );
    foreach my $key (@allowed_keys) {
        # do not pass missing data to let psql assign the default value
        next unless defined $declSpec->{$key};
        $update{$key} = $declSpec->{$key};
        delete $declSpec->{$key};
    }
    # Ensure jobset constraints are met, only have nixexpr{path,input} or
    # flakes set if the type is 0 or 1 respectively. So in the update we need
    # to null the field of the other type.
    if (defined $update{type}) {
        if ($update{type} == 0) {
            $update{flake} = undef;
        } elsif ($update{type} == 1) {
            $update{nixexprpath} = undef;
            $update{nixexprinput} = undef;
        }
    }

    my $enable_dynamic_run_command = defined $update{enable_dynamic_run_command} ? 1 : 0;
    if ($enable_dynamic_run_command
        && !($config->{dynamicruncommand}->{enable}
            && $project->enable_dynamic_run_command))
    {
        die "Dynamic RunCommand is not enabled by the server or the parent project.";
    }

    return %update;
}

sub createJobsetInputsRowAndData {
    my ($name, $declSpec) = @_;
    my $data = $declSpec->{"inputs"}->{$name};
    my $row = {
        name => $name,
        type => $data->{type}
    };
    $row->{emailresponsible} = $data->{emailresponsible} // 0;

    return ($row, $data);
}

sub updateDeclarativeJobset {
    my ($config, $db, $project, $jobsetName, $declSpec) = @_;

    my %update = validateDeclarativeJobset($config, $project, $jobsetName, $declSpec);

    $db->txn_do(sub {
        my $jobset = $project->jobsets->update_or_create(\%update);
        $jobset->jobsetinputs->delete;
        foreach my $name (keys %{$declSpec->{"inputs"}}) {
            my ($row, $data) = createJobsetInputsRowAndData($name, $declSpec);
            my $input = $jobset->jobsetinputs->create($row);
            $input->jobsetinputalts->create({altnr => 0, value => $data->{value}});
        }
        delete $declSpec->{"inputs"};
        die "invalid keys ($declSpec) in declarative specification file\n" if (%{$declSpec});
    });
};

sub handleDeclarativeJobsetJson {
    my ($db, $project, $declSpec) = @_;
    my $config = getHydraConfig();
    $db->txn_do(sub {
            my @kept = keys %$declSpec;
            push @kept, ".jobsets";
            $project->jobsets->search({ name => { "not in" => \@kept } })->update({ enabled => 0, hidden => 1 });
            foreach my $jobsetName (keys %$declSpec) {
                my $spec = $declSpec->{$jobsetName};
                eval {
                    updateDeclarativeJobset($config, $db, $project, $jobsetName, $spec);
                    1;
                } or do {
                    print STDERR "ERROR: failed to process declarative jobset ", $project->name, ":${jobsetName}, ", $@, "\n";
                }
            }
        });
}

sub handleDeclarativeJobsetBuild {
    my ($db, $project, $build) = @_;

    eval {
        my $id = $build->id;
        die "Declarative jobset build $id failed" unless $build->buildstatus == 0;
        my $declPath = ($build->buildoutputs)[0]->path;
        my $declText = eval {
            readNixFile($declPath)
        } or do {
            # If readNixFile errors or returns an undef or an empty string
            print STDERR "ERROR: failed to readNixFile $declPath: ", $@, "\n";
            die;
        };

        my $declSpec = decode_json($declText);
        handleDeclarativeJobsetJson($db, $project, $declSpec);
        1;
    } or do {
        # note the error in the database in the case eval fails for whatever reason
        $project->jobsets->find({ name => ".jobsets" })->update({ errormsg => $@, errortime => time, fetcherrormsg => undef })
    };
};


1;

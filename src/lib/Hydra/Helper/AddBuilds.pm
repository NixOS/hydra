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
    handleDeclarativeJobsetJson
);


sub updateDeclarativeJobset {
    my ($db, $project, $jobsetName, $declSpec) = @_;
    my @errors;

    # keys that are allowed in jobset specs
    my @allowed_keys = qw(
        enabled
        hidden
        description
        type
        flake
        nixexprinput
        nixexprpath
        checkinterval
        schedulingshares
        enableemail
        emailoverride
        keepnr
    );
    # data to write to the db (defaults)
    my %update = (
        type => "legacy",
        nixexprinput => "declInput",
        nixexprpath => "default.nix",
        enableemail => 0,
        name => $jobsetName
    );
    # only allow some keys
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

    # normalize data
    $update{"enabled"} = 2 if $update{"enabled"} eq "oneshot";
    $update{"enabled"} = 3 if $update{"enabled"} eq "oneatatime";
    $update{"type"} = 0 if $update{"type"} eq "legacy";
    $update{"type"} = 1 if $update{"type"} eq "flake";

    # validate data
    push @errors, "Invalid value for 'enabled': $update{enabled}" unless grep { $update{"enabled"} eq $_ } (0..3) or not defined $update{"enabled"};
    push @errors, "Invalid value for 'hidden': $update{hidden}" unless grep { $update{"hidden"} eq $_ } (0..1) or not defined $update{"hidden"};
    push @errors, "Invalid value for 'type': $update{type}" unless grep { $update{"type"} eq $_ } (0..1) or not defined $update{"type"};
    push @errors, "Invalid value for 'checkinterval': $update{checkinterval}" unless $update{"checkinterval"} ge 0 or not defined $update{"checkinterval"};
    push @errors, "Invalid value for 'schedulingshares': $update{schedulingshares}" unless $update{"schedulingshares"} gt 0 or not defined $update{"schedulingshares"};
    push @errors, "Invalid value for 'enableemail': $update{enableemail}" unless grep { $update{"enableemail"} eq $_ } (0..1) or not defined $update{"enableemail"};
    push @errors, "Invalid value for 'keepnr': $update{keepnr}" unless $update{"keepnr"} ge 0 or not defined $update{"keepnr"};

    # insert data
    eval {
        $db->txn_do(sub {
            my $jobset = $project->jobsets->update_or_create(\%update);
            $jobset->jobsetinputs->delete;
            while ((my $name, my $data) = each %{$declSpec->{"inputs"} // {}}) {
                my $row = {
                    name => $name,
                    type => $data->{type}
                };
                $row->{emailresponsible} = $data->{emailresponsible} // 0;
                my $input = $jobset->jobsetinputs->create($row);
                $input->jobsetinputalts->create({altnr => 0, value => $data->{value}});
            }
            delete $declSpec->{"inputs"} if defined $declSpec->{"inputs"};
        });
    } or do {
        chomp $@ if $@;
        push @errors, $@ if $@;
    };
    # check for remaining keys
    for my $key (keys %{$declSpec}) {
        push @errors, "Invalid key '$key' in declarative specification file"
    }
    # output errors
    if (scalar(@errors) gt 0) {
        my $msg = "Errors while evaluating declarative specification file:\n";
        for my $err (@errors) {
            $msg .= "- $err\n";
        }
        die $msg;
    }
};

sub handleDeclarativeJobsetJson {
    my ($db, $project, $declSpec) = @_;
    $db->txn_do(sub {
            my @kept = keys %$declSpec;
            push @kept, ".jobsets";
            $project->jobsets->search({ name => { "not in" => \@kept } })->update({ enabled => 0, hidden => 1 });
            while ((my $jobsetName, my $spec) = each %$declSpec) {
                eval {
                    updateDeclarativeJobset($db, $project, $jobsetName, $spec);
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

package Hydra::Plugin::S3Backup;

use strict;
use parent 'Hydra::Plugin';
use File::Temp;
use File::Basename;
use Fcntl;
use IO::File;
use Net::Amazon::S3;
use Net::Amazon::S3::Client;
use Digest::SHA;
use Nix::Config;
use Nix::Store;
use Hydra::Model::DB;
use Hydra::Helper::CatalystUtils;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{s3backup};
}

my $client;
my %compressors = (
    xz => "| $Nix::Config::xz",
    bzip2 => "| $Nix::Config::bzip2",
    none => ""
);
my $lockfile = Hydra::Model::DB::getHydraPath . "/.hydra-s3backup.lock";

sub buildFinished {
    my ($self, $build, $dependents) = @_;

    return unless $build->buildstatus == 0 or $build->buildstatus == 6;

    my $jobName = showJobName $build;
    my $job = $build->job;

    my $cfg = $self->{config}->{s3backup};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    my @matching_configs = ();
    foreach my $bucket_config (@config) {
        push @matching_configs, $bucket_config if $jobName =~ /^$bucket_config->{jobs}$/;
    }

    return unless @matching_configs;
    unless (defined $client) {
        $client = Net::Amazon::S3::Client->new( s3 => Net::Amazon::S3->new( retry => 1 ) );
    }

    # !!! Maybe should do per-bucket locking?
    my $lockhandle = IO::File->new;
    open($lockhandle, "+>", $lockfile) or die "Opening $lockfile: $!";
    flock($lockhandle, Fcntl::LOCK_SH) or die "Read-locking $lockfile: $!";

    my @needed_paths = ();
    foreach my $output ($build->buildoutputs) {
        push @needed_paths, $output->path;
    }

    my %narinfos = ();
    my %compression_types = ();
    foreach my $bucket_config (@matching_configs) {
        my $compression_type =
          exists $bucket_config->{compression_type} ? $bucket_config->{compression_type} : "bzip2";
        die "Unsupported compression type $compression_type" unless exists $compressors{$compression_type};
        if (exists $compression_types{$compression_type}) {
            push @{$compression_types{$compression_type}}, $bucket_config;
        } else {
            $compression_types{$compression_type} = [ $bucket_config ];
            $narinfos{$compression_type} = [];
        }
    }

    my $build_id = $build->id;
    my $tempdir = File::Temp->newdir("s3-backup-nars-$build_id" . "XXXXX", TMPDIR => 1);

    my %seen = ();
    # Upload nars and build narinfos
    while (@needed_paths) {
        my $path = shift @needed_paths;
        next if exists $seen{$path};
        $seen{$path} = undef;
        my $hash = substr basename($path), 0, 32;
        my ($deriver, $narHash, $time, $narSize, $refs) = queryPathInfo($path, 0);
        my $system;
        if (defined $deriver and isValidPath($deriver)) {
            $system = derivationFromPath($deriver)->{platform};
        }
        foreach my $reference (@{$refs}) {
            push @needed_paths, $reference;
        }
        while (my ($compression_type, $configs) = each %compression_types) {
            my @incomplete_buckets = ();
            # Don't do any work if all the buckets have this path
            foreach my $bucket_config (@{$configs}) {
                my $bucket = $client->bucket( name => $bucket_config->{name} );
                my $prefix = exists $bucket_config->{prefix} ? $bucket_config->{prefix} : "";
                push @incomplete_buckets, $bucket_config
                  unless $bucket->object( key => $prefix . "$hash.narinfo" )->exists;
            }
            next unless @incomplete_buckets;
            my $compressor = $compressors{$compression_type};
            system("$Nix::Config::binDir/nix-store --dump $path $compressor > $tempdir/nar") == 0 or die;
            my $digest = Digest::SHA->new(256);
            $digest->addfile("$tempdir/nar");
            my $file_hash = $digest->hexdigest;
            my @stats = stat "$tempdir/nar" or die "Couldn't stat $tempdir/nar";
            my $file_size = $stats[7];
            my $narinfo = "";
            $narinfo .= "StorePath: $path\n";
            $narinfo .= "URL: $hash.nar\n";
            $narinfo .= "Compression: $compression_type\n";
            $narinfo .= "FileHash: sha256:$file_hash\n";
            $narinfo .= "FileSize: $file_size\n";
            $narinfo .= "NarHash: $narHash\n";
            $narinfo .= "NarSize: $narSize\n";
            $narinfo .= "References: " . join(" ", map { basename $_ } @{$refs}) . "\n";
            if (defined $deriver) {
                $narinfo .= "Deriver: " . basename $deriver . "\n";
                if (defined $system) {
                    $narinfo .= "System: $system\n";
                }
            }
            push @{$narinfos{$compression_type}}, { hash => $hash, info => $narinfo };
            foreach my $bucket_config (@incomplete_buckets) {
                my $bucket = $client->bucket( name => $bucket_config->{name} );
                my $prefix = exists $bucket_config->{prefix} ? $bucket_config->{prefix} : "";
                my $nar_object = $bucket->object(
                    key => $prefix . "$hash.nar",
                    content_type => "application/x-nix-archive"
                );
                $nar_object->put_filename("$tempdir/nar");
            }
        }
    }

    # Upload narinfos
    while (my ($compression_type, $infos) = each %narinfos) {
        foreach my $bucket_config (@{$compression_types{$compression_type}}) {
            foreach my $info (@{$infos}) {
                my $bucket = $client->bucket( name => $bucket_config->{name} );
                my $prefix = exists $bucket_config->{prefix} ? $bucket_config->{prefix} : "";
                my $narinfo_object = $bucket->object(
                    key => $prefix . $info->{hash} . ".narinfo",
                    content_type => "text/x-nix-narinfo"
                );
                $narinfo_object->put($info->{info}) unless $narinfo_object->exists;
            }
        }
    }
}

1;

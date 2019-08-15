package Hydra::Plugin::CoverityScan;

use strict;
use parent 'Hydra::Plugin';
use File::Basename;
use LWP::UserAgent;
use Hydra::Helper::CatalystUtils;

sub isEnabled {
    my ($self) = @_;
    return defined $self->{config}->{coverityscan};
}

sub buildFinished {
    my ($self, $b, $dependents) = @_;

    my $cfg = $self->{config}->{coverityscan};
    my @config = defined $cfg ? ref $cfg eq "ARRAY" ? @$cfg : ($cfg) : ();

    # Scan the job and see if it matches any of the Coverity Scan projects
    my $proj;
    my $jobName = showJobName $b;
    foreach my $p (@config) {
        next unless $jobName =~ /^$p->{jobs}$/;

        # If build is cancelled or aborted, do not upload build
        next if $b->buildstatus == 4 || $b->buildstatus == 3;

        # Otherwise, select this Coverity project
        $proj = $p; last;
    }

    # Bail if there's no matching project
    return unless defined $proj;

    # Compile submission information
    my $project = $proj->{project};
    my $email   = $proj->{email};
    my $token   = $proj->{token};
    my $scanurl = $proj->{scanurl} || "http://scan5.coverity.com/cgi-bin/upload.py";

    # Sanity checks
    die "coverity project name not configured" unless defined $project;
    die "email must be specified for Coverity project '".$project."'"
        unless defined $email;
    die "access token must be specified for Coverity project '".$project."'"
        unless defined $token;

    # Get tarball locations
    my $storePath = ($b->buildoutputs)[0]->path;
    my $tarballs  = "$storePath/tarballs";
    my $covTarball;

    opendir TARBALLS, $tarballs or die;
    while (readdir TARBALLS) {
        next unless $_ =~ /.*-coverity-int\.(tgz|lzma|xz|bz2|zip)$/;
        $covTarball = "$tarballs/$_"; last;
    }
    closedir TARBALLS;

    unless (defined $covTarball) {
        print STDERR "CoverityScan.pm: Coverity tarball not found in $tarballs; skipping upload...\n";
        return;
    }

    # Find the file mimetype
    my @exts = qw(.xz .bz2 .lzma .zip .tgz);
    my ($dir, $file, $ext) = fileparse($covTarball, @exts);
    my $mimetype;
    if ($ext eq '.xz') { $mimetype = "application/x-xz"; }
    elsif ($ext eq '.lzma') { $mimetype = "application/x-xz"; }
    elsif ($ext eq '.zip') { $mimetype = "application/zip"; }
    elsif ($ext eq '.bz2') { $mimetype = "application/x-bzip2"; }
    elsif ($ext eq '.tgz') { $mimetype = "application/x-gzip"; }
    else { die "couldn't parse extension of $covTarball"; }

    die "couldn't detect mimetype of $covTarball" unless defined $mimetype;

    # Parse version number from tarball
    my $pkgNameRE = "(?:(?:[A-Za-z0-9]|(?:-[^0-9]))+)";
    my $versionRE = "(?:[A-Za-z0-9\.\-]+)";

    my $shortName = basename($covTarball);
    my $version = $2 if $shortName =~ /^($pkgNameRE)-($versionRE)-coverity-int.*$/;

    die "CoverityScan.pm: Couldn't parse build version for upload! ($shortName)"
        unless defined $version;

    # Submit build
    my $jobid = $b->id;
    my $desc = "Hydra Coverity Build ($jobName) - $jobid:$version";

    print STDERR "uploading $desc ($shortName) to Coverity Scan\n";

    my $ua = LWP::UserAgent->new();
    my $resp = $ua->post($scanurl,
            Content_Type => 'form-data',
            Content => [
                project     => $project,
                email       => $email,
                token       => $token,
                version     => $version,
                description => $desc,
                file        => [ $covTarball, $shortName,
                    Content_Type => $mimetype,
                ],
            ],
        );

    # The Coverity HTTP endpoint doesn't handle errors very well, and always
    # returns a 200 :(
    my $results = $resp->decoded_content;
    if ($results =~ /ERROR!/) {
        print STDERR "CoverityScan.pm: upload error - ", $resp->decoded_content, "\n";
        return;
    }

    # Just for sanity, in case things change later
    unless ($results =~ /Your request has been submitted/) {
        print STDERR "CoverityScan.pm: upload error, didn't find expected response - ", $resp->decoded_content, "\n";
    }
}

1;

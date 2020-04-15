package Hydra::Plugin::SoTest;

use strict;
use parent 'Hydra::Plugin';
use Hydra::Helper::CatalystUtils;
use HTTP::Request;
use LWP::UserAgent;

=encoding utf8

=head1 NAME

SoTest - hydra-notify plugin for scheduling hardware tests

=head1 DESCRIPTION

This plugin submits tests to a SoTest controller for all builds that contain
two products matching the subtypes "sotest-binaries" and "sotest-config".

Build products are declared by the file "nix-support/hydra-build-products"
relative to the root of a build, in the following format:

 file sotest-binaries /nix/store/…/binaries.zip
 file sotest-config /nix/store/…/config.yaml

=head1 CONFIGURATION

The plugin is configured by a C<sotest> block in the Hydra config file
(services.hydra.extraConfig within NixOS).

 <sotest>
 uri = https://sotest.example # defaults to https://opensource.sotest.io
 username = Aladdin
 password = OpenSesame
 priority = 1 # optional
 </sotest>

=head1 AUTHOR

Emery Hemingway <ehmry@posteo.net>

=cut

sub _logIfDebug {
    my ($msg) = @_;
    print {*STDERR} "SoTest: $msg\n" if $ENV{'HYDRA_DEBUG'};
    return;
}

sub isEnabled {
    my ($self) = @_;

    if ( defined $self->{config}->{sotest} ) {
        _logIfDebug 'plugin enabled';
    }
    else {
        _logIfDebug 'plugin disabled';
        return 0;
    }

    my $sotest = $self->{config}->{sotest};
    die 'SoTest username and password must be specified'
      unless ( defined $sotest->{username} and defined $sotest->{password} );

    return 1;
}

sub buildFinished {
    my ( $self, $build, $dependents ) = @_;
    my $baseurl = $self->{config}->{'base_uri'} || 'http://localhost:3000';
    my $sotest  = $self->{config}->{sotest};

    my $sotest_boot_files_url;
    my $sotest_config;

    for my $product ( $build->buildproducts ) {
        if ( 'sotest-binaries' eq $product->subtype ) {
            $sotest_boot_files_url = join q{/}, $baseurl, 'build', $build->id,
              'download', $product->productnr, $product->name;
        }
        elsif ( 'sotest-config' eq $product->subtype ) {
            $sotest_config = $product->path;
        }
    }

    unless ( defined $sotest_boot_files_url and defined $sotest_config ) {
        _logIfDebug 'skipping build ', showJobName $build;
        return;
    }

    my $sotest_name     = showJobName $build;
    my $sotest_url      = "${\$baseurl}/build/${\$build->id}";
    my $sotest_priority = int( $sotest->{priority} || '0' );

    _logIfDebug 'post job for ', $sotest_name;

    my $ua = LWP::UserAgent->new();
    $ua->default_headers->authorization_basic( $sotest->{username},
        $sotest->{password} );

    my $res = $ua->post(
        ( $sotest->{uri} || 'https://opensource.sotest.io' ) . '/api/create',
        'Content-Type' => 'multipart/form-data',
        Content        => [
            boot_files_url => $sotest_boot_files_url,
            name           => $sotest_name,
            url            => $sotest_url,
            config         => ["$sotest_config"],
            priority       => $sotest_priority,
        ],
    );

    _logIfDebug $res->status_line;
    _logIfDebug $res->decoded_content;

    die "${\$res->status_line}: ${\$res->decoded_content}"
      unless ( $res->is_success );

    return;
}

1;

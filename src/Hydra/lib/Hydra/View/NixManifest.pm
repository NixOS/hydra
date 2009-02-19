package Hydra::View::NixManifest;

use strict;
use base qw/Catalyst::View/;
use IO::Pipe;
use IPC::Run;
use POSIX qw(dup2);

sub captureStdoutStderr {
    my $stdin = ""; my $stdout; my $stderr;
    my $res = IPC::Run::run(\@_, \$stdin, \$stdout, \$stderr);
    return ($res, $stdout, $stderr);
}


sub process {
    my ($self, $c) = @_;

    my $storePath = $c->stash->{storePath};
    
    $c->response->content_type('text/x-nix-manifest');

    my @paths = split '\n', `nix-store --query --requisites $storePath`
        or die "cannot query dependencies of `$storePath': $?";

    my $manifest =
        "version {\n" .
        "  ManifestVersion: 3\n" .
        "}\n";
    
    foreach my $path (@paths) {
        my ($res, $out, $err) = captureStdoutStderr(qw(nix-store --query --references), $path);
        die "cannot query references of `$path':\n$err" unless $res;
        my @refs = split '\n', $out;
        
        my $hash = `nix-store --query --hash $path`
            or die "cannot query hash of `$path': $?";
        chomp $hash;

        my $url = $c->uri_for('/nar' . $path);
        
        $manifest .=
            "{\n" .
            "  StorePath: ${path}y\n" .
            "  NarURL: $url\n" .
            "  References: @refs\n" .
            "  NarHash: $hash\n" .
            "}\n";
    }

    $c->response->body($manifest);

    return 1;
}

1;

package Nix::Utils;

use utf8;
use strict;
use warnings;
use File::Temp qw(tempdir);

our @ISA = qw(Exporter);
our @EXPORT = qw(checkURL uniq writeFile readFile mkTempDir);

our $urlRE = "(?: [a-zA-Z][a-zA-Z0-9\+\-\.]*\:[a-zA-Z0-9\%\/\?\:\@\&\=\+\$\,\-\_\.\!\~\*]+ )";

sub checkURL {
    my ($url) = @_;
    die "invalid URL '$url'\n" unless $url =~ /^ $urlRE $ /x;
}

sub uniq {
    my %seen;
    my @res;
    foreach my $name (@_) {
        next if $seen{$name};
        $seen{$name} = 1;
        push @res, $name;
    }
    return @res;
}

sub writeFile {
    my ($fn, $s) = @_;
    open my $fh, ">", $fn or die "cannot create file '$fn': $!";
    print $fh "$s" or die;
    close $fh or die;
}

sub readFile {
    local $/ = undef;
    my ($fn) = @_;
    open my $fh, "<", $fn or die "cannot open file '$fn': $!";
    my $s = <$fh>;
    close $fh or die;
    return $s;
}

sub mkTempDir {
    my ($name) = @_;
    return tempdir("$name.XXXXXX", CLEANUP => 1, DIR => $ENV{"TMPDIR"} // $ENV{"XDG_RUNTIME_DIR"} // "/tmp")
        || die "cannot create a temporary directory";
}

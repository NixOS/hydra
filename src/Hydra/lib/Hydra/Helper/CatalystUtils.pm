package Hydra::Helper::CatalystUtils;

use strict;
use Exporter;
use Readonly;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getBuild error notFound
    $pathCompRE $relPathRE
);


sub getBuild {
    my ($c, $id) = @_;
    my $build = $c->model('DB::Builds')->find($id);
    return $build;
}


sub error {
    my ($c, $msg) = @_;
    $c->error($msg);
    $c->detach;
}


sub notFound {
    my ($c, $msg) = @_;
    $c->response->status(404);
    error($c, $msg);
}


# Security checking of filenames.
Readonly::Scalar our $pathCompRE => "(?:[A-Za-z0-9-\+][A-Za-z0-9-\+\._]*)";
Readonly::Scalar our $relPathRE  => "(?:$pathCompRE(?:\/$pathCompRE)*)";


1;

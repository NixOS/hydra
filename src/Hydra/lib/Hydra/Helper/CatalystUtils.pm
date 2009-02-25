package Hydra::Helper::CatalystUtils;

use strict;
use Exporter;

our @ISA = qw(Exporter);
our @EXPORT = qw(getBuild error notFound);


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


1;

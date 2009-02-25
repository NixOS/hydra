package Hydra::Controller::Build;

use strict;
use warnings;
use parent 'Catalyst::Controller';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


# Security checking of filenames.
my $pathCompRE = "(?:[A-Za-z0-9-\+][A-Za-z0-9-\+\._]*)";
my $relPathRE = "(?:$pathCompRE(?:\/$pathCompRE)*)";


sub build : Chained('/') PathPart CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    
    $c->stash->{id} = $id;
    
    $c->stash->{build} = getBuild($c, $id);
    
    if (!defined $c->stash->{build}) {
        error($c, "Build with ID $id doesn't exist.");
        $c->response->status(404);
        return;
    }

    $c->stash->{curProject} = $c->stash->{build}->project;
}


sub view_build : Chained('build') PathPart('') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};
    
    $c->stash->{template} = 'build.tt';
    $c->stash->{curTime} = time;
    $c->stash->{available} = isValidPath $build->outpath;

    if (!$build->finished && $build->schedulingInfo->busy) {
        my $logfile = $build->schedulingInfo->logfile;
        $c->stash->{logtext} = `cat $logfile`;
    }
}


sub view_nixlog : Chained('build') PathPart('nixlog') Args(1) {
    my ($self, $c, $stepnr) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    return error($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{template} = 'log.tt';
    $c->stash->{step} = $step;

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($c, $step->logfile);
}


sub view_log : Chained('build') PathPart('log') Args(0) {
    my ($self, $c) = @_;

    return error($c, "Build didn't produce a log.") if !defined $c->stash->{build}->resultInfo->logfile;

    $c->stash->{template} = 'log.tt';

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($c, $c->stash->{build}->resultInfo->logfile);
}


sub loadLog {
    my ($c, $path) = @_;

    die unless defined $path;

    # !!! quick hack
    my $pipeline = ($path =~ /.bz2$/ ? "cat $path | bzip2 -d" : "cat $path")
        . " | nix-log2xml | xsltproc " . $c->path_to("xsl/mark-errors.xsl") . " -"
        . " | xsltproc " . $c->path_to("xsl/log2html.xsl") . " - | tail -n +2";

    return `$pipeline`;
}


sub download : Chained('build') PathPart('download') {
    my ($self, $c, $productnr, $filename, @path) = @_;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    return error($c, "Build doesn't have a product $productnr.") if !defined $product;

    return error($c, "Product " . $product->path . " has disappeared.") unless -e $product->path;

    # Security paranoia.
    foreach my $elem (@path) {
        return error($c, "Invalid filename $elem.") if $elem !~ /^$pathCompRE$/;
    }
    
    my $path = $product->path;
    $path .= "/" . join("/", @path) if scalar @path > 0;

    # If this is a directory but no "/" is attached, then redirect.
    if (-d $path && substr($c->request->uri, -1) ne "/") {
        return $c->res->redirect($c->request->uri . "/");
    }
    
    $path = "$path/index.html" if -d $path && -e "$path/index.html";

    if (!-e $path) {
        return error($c, "File $path does not exist.");
    }

    $c->serve_static_file($path);
}


1;

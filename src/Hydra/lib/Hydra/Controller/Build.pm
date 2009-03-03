package Hydra::Controller::Build;

use strict;
use warnings;
use base 'Hydra::Base::Controller::Nix';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub build : Chained('/') PathPart CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    
    $c->stash->{id} = $id;
    
    $c->stash->{build} = getBuild($c, $id);

    notFound($c, "Build with ID $id doesn't exist.")
        if !defined $c->stash->{build};

    $c->stash->{curProject} = $c->stash->{build}->project;
}


sub view_build : Chained('build') PathPart('') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};
    
    $c->stash->{template} = 'build.tt';
    $c->stash->{curTime} = time;
    $c->stash->{available} = isValidPath $build->outpath;
    $c->stash->{drvAvailable} = isValidPath $build->drvpath;
    $c->stash->{flashMsg} = $c->flash->{afterRestart};

    if (!$build->finished && $build->schedulingInfo->busy) {
        my $logfile = $build->schedulingInfo->logfile;
        $c->stash->{logtext} = `cat $logfile`;
    }
}


sub view_nixlog : Chained('build') PathPart('nixlog') Args(1) {
    my ($self, $c, $stepnr) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    notFound($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{template} = 'log.tt';
    $c->stash->{step} = $step;

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($c, $step->logfile);
}


sub view_log : Chained('build') PathPart('log') Args(0) {
    my ($self, $c) = @_;

    error($c, "Build didn't produce a log.") if !defined $c->stash->{build}->resultInfo->logfile;

    $c->stash->{template} = 'log.tt';

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($c, $c->stash->{build}->resultInfo->logfile);
}


sub loadLog {
    my ($c, $path) = @_;

    notFound($c, "Log file $path no longer exists.") unless -f $path;
    
    # !!! quick hack
    my $pipeline = ($path =~ /.bz2$/ ? "cat $path | bzip2 -d" : "cat $path")
        . " | nix-log2xml | xsltproc " . $c->path_to("xsl/mark-errors.xsl") . " -"
        . " | xsltproc " . $c->path_to("xsl/log2html.xsl") . " - | tail -n +2";

    return `$pipeline`;
}


sub download : Chained('build') PathPart('download') {
    my ($self, $c, $productnr, $filename, @path) = @_;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    notFound($c, "Build doesn't have a product $productnr.") if !defined $product;

    notFound($c, "Product " . $product->path . " has disappeared.") unless -e $product->path;

    # Security paranoia.
    foreach my $elem (@path) {
        error($c, "Invalid filename $elem.") if $elem !~ /^$pathCompRE$/;
    }
    
    my $path = $product->path;
    $path .= "/" . join("/", @path) if scalar @path > 0;

    # If this is a directory but no "/" is attached, then redirect.
    if (-d $path && substr($c->request->uri, -1) ne "/") {
        return $c->res->redirect($c->request->uri . "/");
    }
    
    $path = "$path/index.html" if -d $path && -e "$path/index.html";

    notFound($c, "File $path does not exist.") if !-e $path;

    $c->serve_static_file($path);
}


sub runtimedeps : Chained('build') PathPart('runtime-deps') {
    my ($self, $c) = @_;
    
    my $build = $c->stash->{build};
    
    notFound($c, "Path " . $build->outpath . " is no longer available.")
        unless isValidPath($build->outpath);
    
    $c->stash->{current_view} = 'Hydra::View::NixDepGraph';
    $c->stash->{storePaths} = [$build->outpath];
    
    $c->response->content_type('image/png'); # !!!
}


sub buildtimedeps : Chained('build') PathPart('buildtime-deps') {
    my ($self, $c) = @_;
    
    my $build = $c->stash->{build};
    
    notFound($c, "Path " . $build->drvpath . " is no longer available.")
        unless isValidPath($build->drvpath);
    
    $c->stash->{current_view} = 'Hydra::View::NixDepGraph';
    $c->stash->{storePaths} = [$build->drvpath];
    
    $c->response->content_type('image/png'); # !!!
}


sub nix : Chained('build') PathPart('nix') CaptureArgs(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    notFound($c, "Build cannot be downloaded as a closure or Nix package.")
        if !$build->buildproducts->find({type => "nix-build"});

    notFound($c, "Path " . $build->outpath . " is no longer available.")
        unless isValidPath($build->outpath);
    
    $c->stash->{storePaths} = [$build->outpath];
    
    my $pkgName = $build->nixname . "-" . $build->system . ".nixpkg";
    $c->stash->{nixPkgs} = {$pkgName => $build};
}


sub restart : Chained('build') PathPart('restart') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    error($c, "This build cannot be restarted.")
        unless $build->finished && $build->resultInfo->buildstatus == 3;

    $c->model('DB')->schema->txn_do(sub {
        $build->finished(0);
        $build->timestamp(time());
        $build->update;

        $build->resultInfo->delete;

        $c->model('DB::BuildSchedulingInfo')->create(
            { id => $build->id
            , priority => 0 # don't know the original priority anymore...
            , busy => 0
            , locker => ""
            });
    });

    $c->flash->{afterRestart} = "Build has been restarted.";
    
    $c->response->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


1;

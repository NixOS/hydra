package Hydra::Controller::Build;

use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;


sub build : Chained('/') PathPart CaptureArgs(1) {
    my ($self, $c, $id) = @_;
    
    $c->stash->{id} = $id;
    
    $c->stash->{build} = getBuild($c, $id);

    notFound($c, "Build with ID $id doesn't exist.")
        if !defined $c->stash->{build};

    $c->stash->{project} = $c->stash->{build}->project;
}


sub view_build : Chained('build') PathPart('') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};
    
    $c->stash->{template} = 'build.tt';
    $c->stash->{curTime} = time;
    $c->stash->{available} = isValidPath $build->outpath;
    $c->stash->{drvAvailable} = isValidPath $build->drvpath;
    $c->stash->{flashMsg} = $c->flash->{buildMsg};

    if (!$build->finished && $build->schedulingInfo->busy) {
        my $logfile = $build->schedulingInfo->logfile;
        $c->stash->{logtext} = `cat $logfile` if -e $logfile;
    }
}


sub view_nixlog : Chained('build') PathPart('nixlog') {
    my ($self, $c, $stepnr, $mode) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    notFound($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{step} = $step;

    showLog($c, $step->logfile, $mode);
}


sub view_log : Chained('build') PathPart('log') {
    my ($self, $c, $mode) = @_;

    error($c, "Build didn't produce a log.") if !defined $c->stash->{build}->resultInfo->logfile;

    showLog($c, $c->stash->{build}->resultInfo->logfile, $mode);
}


sub showLog {
    my ($c, $path, $mode) = @_;

    notFound($c, "Log file $path no longer exists.") unless -f $path;

    if (!$mode) {
        # !!! quick hack
        my $pipeline = ($path =~ /.bz2$/ ? "cat $path | bzip2 -d" : "cat $path")
            . " | nix-log2xml | xsltproc " . $c->path_to("xsl/mark-errors.xsl") . " -"
            . " | xsltproc " . $c->path_to("xsl/log2html.xsl") . " - | tail -n +2";

        $c->stash->{template} = 'log.tt';
        $c->stash->{logtext} = `$pipeline`;
    }

    elsif ($mode eq "raw") {
        $c->serve_static_file($path);
    }

    elsif ($mode eq "tail") {
        $c->stash->{'plain'} = { data => (scalar `tail -n 50 $path`) || " " };
        $c->forward('Hydra::View::Plain');
    }

    else {
        error($c, "Unknown log display mode `$mode'.");
    }
}


sub defaultUriForProduct {
    my ($self, $c, $product, @path) = @_;
    my $x = $product->productnr
        . ($product->name ? "/" . $product->name : "")
        . ($product->defaultpath ? "/" . $product->defaultpath : ""); 
    return $c->uri_for($self->action_for("download"), $c->req->captures, $x, @path);
}


sub download : Chained('build') PathPart {
    my ($self, $c, $productnr, @path) = @_;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    notFound($c, "Build doesn't have a product $productnr.") if !defined $product;

    notFound($c, "Product " . $product->path . " has disappeared.") unless -e $product->path;

    return $c->res->redirect(defaultUriForProduct($self, $c, $product, @path))
        if scalar @path == 0 && ($product->name || $product->defaultpath);
    
    # If the product has a name, then the first path element can be
    # ignored (it's the name included in the URL for informational purposes).
    shift @path if $product->name; 
    
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

    notFound($c, "Path $path is a directory.") if -d $path;

    $c->serve_static_file($path);
}


# Redirect to a download with the given type.  Useful when you want to
# link to some build product of the latest build (i.e. in conjunction
# with the .../latest redirect).
sub download_by_type : Chained('build') PathPart('download-by-type') {
    my ($self, $c, $type, $subtype, @path) = @_;

    notFound($c, "You need to specify a type and a subtype in the URI.")
        unless defined $type && defined $subtype;

    (my $product) = $c->stash->{build}->buildproducts->search(
        {type => $type, subtype => $subtype});
    notFound($c, "Build doesn't have a build product with type $type/$subtype.")
        if !defined $product;

    $c->res->redirect(defaultUriForProduct($self, $c, $product, @path));
}


sub contents : Chained('build') PathPart Args(1) {
    my ($self, $c, $productnr) = @_;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    notFound($c, "Build doesn't have a product $productnr.") if !defined $product;

    my $path = $product->path;
    
    notFound($c, "Product $path has disappeared.") unless -e $path;

    my $res;

    if ($product->type eq "nix-build") {
        $res = `cd $path && find . -print0 | xargs -0 ls -ld --`;
        error($c, "`ls -lR' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.rpm$/) {
        $res = `rpm --query --info --package "$path"`;
        error($c, "RPM error: $?") if $? != 0;
        $res .= "===\n";
        $res .= `rpm --query --list --verbose --package "$path"`;
        error($c, "RPM error: $?") if $? != 0;
    }

    elsif ($path =~ /\.deb$/) {
        $res = `dpkg-deb --info "$path"`;
        error($c, "`dpkg-deb' error: $?") if $? != 0;
        $res .= "===\n";
        $res .= `dpkg-deb --contents "$path"`;
        error($c, "`dpkg-deb' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.tar(\.gz|\.bz2|\.lzma)?$/ ) {
        $res = `tar tvfa "$path"`;
        error($c, "`tar' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.zip$/ ) {
        $res = `unzip -v "$path"`;
        error($c, "`unzip' error: $?") if $? != 0;
    }

    else {
        error($c, "Unsupported file type.");
    }

    die unless $res;
    
    $c->stash->{'plain'} = { data => $res };
    $c->forward('Hydra::View::Plain');
}


sub runtimedeps : Chained('build') PathPart('runtime-deps') {
    my ($self, $c) = @_;
    
    my $build = $c->stash->{build};
    
    notFound($c, "Path " . $build->outpath . " is no longer available.")
        unless isValidPath($build->outpath);
    
    $c->stash->{current_view} = 'Hydra::View::NixDepGraph';
    $c->stash->{storePaths} = [$build->outpath];
    
    $c->res->content_type('image/png'); # !!!
}


sub buildtimedeps : Chained('build') PathPart('buildtime-deps') {
    my ($self, $c) = @_;
    
    my $build = $c->stash->{build};
    
    notFound($c, "Path " . $build->drvpath . " is no longer available.")
        unless isValidPath($build->drvpath);
    
    $c->stash->{current_view} = 'Hydra::View::NixDepGraph';
    $c->stash->{storePaths} = [$build->drvpath];
    
    $c->res->content_type('image/png'); # !!!
}


sub nix : Chained('build') PathPart('nix') CaptureArgs(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    notFound($c, "Build cannot be downloaded as a closure or Nix package.")
        if !$build->buildproducts->find({type => "nix-build"});

    notFound($c, "Path " . $build->outpath . " is no longer available.")
        unless isValidPath($build->outpath);
    
    $c->stash->{storePaths} = [$build->outpath];
    
    my $pkgName = $build->nixname . "-" . $build->system;
    $c->stash->{nixPkgs} = {"${pkgName}.nixpkg" => {build => $build, name => $pkgName}};
}


sub restart : Chained('build') PathPart Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    $c->model('DB')->schema->txn_do(sub {
        error($c, "This build cannot be restarted.")
            unless $build->finished &&
              ($build->resultInfo->buildstatus == 3 ||
               $build->resultInfo->buildstatus == 4);

        $build->update({finished => 0, timestamp => time});

        $build->resultInfo->delete;

        $c->model('DB::BuildSchedulingInfo')->create(
            { id => $build->id
            , priority => 0 # don't know the original priority anymore...
            , busy => 0
            , locker => ""
            });
    });

    $c->flash->{buildMsg} = "Build has been restarted.";
    
    $c->res->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


sub cancel : Chained('build') PathPart Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    $c->model('DB')->schema->txn_do(sub {
        error($c, "This build cannot be cancelled.")
            if $build->finished || $build->schedulingInfo->busy;

        # !!! Actually, it would be nice to be able to cancel busy
        # builds as well, but we would have to send a signal or
        # something to the build process.

        $build->update({finished => 1, timestamp => time});

        $c->model('DB::BuildResultInfo')->create(
            { id => $build->id
            , iscachedbuild => 0
            , buildstatus => 4 # = cancelled
            });

        $build->schedulingInfo->delete;
    });

    $c->flash->{buildMsg} = "Build has been cancelled.";
    
    $c->res->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


sub keep : Chained('build') PathPart Args(1) {
    my ($self, $c, $newStatus) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    die unless $newStatus == 0 || $newStatus == 1;

    registerRoot $build->outpath if $newStatus == 1;

    $c->model('DB')->schema->txn_do(sub {
        $build->resultInfo->update({keep => int $newStatus});
    });

    $c->flash->{buildMsg} =
        $newStatus == 0 ? "Build will not be kept." : "Build will be kept.";
    
    $c->res->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


1;

package Hydra::Controller::Build;

use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::AddBuilds;
use File::stat;
use File::Slurp;
use Data::Dump qw(dump);
use Nix::Store;
use Nix::Config;
use List::MoreUtils qw(all);


sub build : Chained('/') PathPart CaptureArgs(1) {
    my ($self, $c, $id) = @_;

    $c->stash->{id} = $id;

    $c->stash->{build} = getBuild($c, $id);

    notFound($c, "Build with ID $id doesn't exist.")
        if !defined $c->stash->{build};

    $c->stash->{prevBuild} = getPreviousBuild($c, $c->stash->{build});
    $c->stash->{prevSuccessfulBuild} = getPreviousSuccessfulBuild($c, $c->stash->{build});
    $c->stash->{firstBrokenBuild} = getNextBuild($c, $c->stash->{prevSuccessfulBuild});

    $c->stash->{mappers} = [$c->model('DB::UriRevMapper')->all];

    $c->stash->{project} = $c->stash->{build}->project;
}


sub findBuildStepByOutPath {
    my ($self, $c, $path, $status) = @_;
    return $c->model('DB::BuildSteps')->search(
        { path => $path, busy => 0, status => $status },
        { join => ["buildstepoutputs"], order_by => ["stopTime"], limit => 1 })->single;
}


sub findBuildStepByDrvPath {
    my ($self, $c, $drvPath, $status) = @_;
    return $c->model('DB::BuildSteps')->search(
        { drvpath => $drvPath, busy => 0, status => $status },
        { order_by => ["stopTime"], limit => 1 })->single;
}


sub view_build : Chained('build') PathPart('') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    $c->stash->{template} = 'build.tt';
    $c->stash->{available} = all { isValidPath($_->path) } $build->buildoutputs->all;
    $c->stash->{drvAvailable} = isValidPath $build->drvpath;
    $c->stash->{flashMsg} = $c->flash->{buildMsg};

    if (!$build->finished && $build->busy) {
        $c->stash->{logtext} = read_file($build->logfile, err_mode => 'quiet') // "";
    }

    if ($build->finished && $build->iscachedbuild) {
        my $path = ($build->buildoutputs)[0]->path or die;
        my $cachedBuildStep = findBuildStepByOutPath($self, $c, $path,
            $build->buildstatus == 0 || $build->buildstatus == 6 ? 0 : 1);
        $c->stash->{cachedBuild} = $cachedBuildStep->build if defined $cachedBuildStep;
    }

    if ($build->finished && 0) {
        $c->stash->{prevBuilds} = [$c->model('DB::Builds')->search(
            { project => $c->stash->{project}->name
            , jobset => $c->stash->{build}->jobset->name
            , job => $c->stash->{build}->job->name
            , 'me.system' => $build->system
            , finished => 1
            , buildstatus => 0
            , 'me.id' =>  { '<=' => $build->id }
            }
          , { join => "actualBuildStep"
            , "+select" => ["actualBuildStep.stoptime - actualBuildStep.starttime"]
            , "+as" => ["actualBuildTime"]
            , order_by => "me.id DESC"
            , rows => 50
            }
          )
        ];
    }

    # Get the first eval of which this build was a part.
    ($c->stash->{nrEvals}) = $c->stash->{build}->jobsetevals->search({ hasnewbuilds => 1 })->count;
    ($c->stash->{eval}) = $c->stash->{build}->jobsetevals->search(
        { hasnewbuilds => 1},
        { limit => 1, order_by => ["id"] });
}


sub view_nixlog : Chained('build') PathPart('nixlog') {
    my ($self, $c, $stepnr, $mode) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    notFound($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{step} = $step;

    showLog($c, $step->drvpath, $mode);
}


sub view_log : Chained('build') PathPart('log') {
    my ($self, $c, $mode) = @_;
    showLog($c, $c->stash->{build}->drvpath, $mode);
}


sub showLog {
    my ($c, $drvPath, $mode) = @_;

    my $logPath = getDrvLogPath($drvPath);

    notFound($c, "The build log of derivation ‘$drvPath’ is not available.") unless defined $logPath;

    if (!$mode) {
        # !!! quick hack
        my $pipeline = "nix-store -l $drvPath"
            . " | nix-log2xml | xsltproc " . $c->path_to("xsl/mark-errors.xsl") . " -"
            . " | xsltproc " . $c->path_to("xsl/log2html.xsl") . " - | tail -n +2";
        $c->stash->{template} = 'log.tt';
        $c->stash->{logtext} = `$pipeline`;
    }

    elsif ($mode eq "raw") {
        $c->stash->{'plain'} = { data => (scalar logContents($drvPath)) || " " };
        $c->forward('Hydra::View::Plain');
    }

    elsif ($mode eq "tail-reload") {
        my $url = $c->request->uri->as_string;
        $url =~ s/tail-reload/tail/g;
        $c->stash->{url} = $url;
        $c->stash->{reload} = !$c->stash->{build}->finished && $c->stash->{build}->busy;
        $c->stash->{title} = "";
        $c->stash->{contents} = (scalar logContents($drvPath, 50)) || " ";
        $c->stash->{template} = 'plain-reload.tt';
    }

    elsif ($mode eq "tail") {
        $c->stash->{'plain'} = { data => (scalar logContents($drvPath, 50)) || " " };
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
    return $c->uri_for($self->action_for("download"), $c->req->captures, (split /\//, $x), @path);
}


sub checkPath {
    my ($self, $c, $path) = @_;
    my $storeDir = $Nix::Config::storeDir . "/";
    error($c, "Invalid path in build product.")
        if substr($path, 0, length($storeDir)) ne $storeDir || $path =~ /\/\.\./;
    error($c, "Path ‘$path’ is a symbolic link.") if -l $path;
}


sub download : Chained('build') PathPart {
    my ($self, $c, $productnr, @path) = @_;

    $productnr = 1 if !defined $productnr;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    notFound($c, "Build doesn't have a product #$productnr.") if !defined $product;

    notFound($c, "Build product " . $product->path . " has disappeared.") unless -e $product->path;

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

    # Make sure the file is in the Nix store.
    checkPath($self, $c, $path);

    # If this is a directory but no "/" is attached, then redirect.
    if (-d $path && substr($c->request->uri, -1) ne "/") {
        return $c->res->redirect($c->request->uri . "/");
    }

    $path = "$path/index.html" if -d $path && -e "$path/index.html";

    notFound($c, "File $path does not exist.") if !-e $path;

    notFound($c, "Path $path is a directory.") if -d $path;

    $c->serve_static_file($path);
    $c->response->headers->last_modified($c->stash->{build}->timestamp);
}


# Redirect to a download with the given type.  Useful when you want to
# link to some build product of the latest build (i.e. in conjunction
# with the .../latest redirect).
sub download_by_type : Chained('build') PathPart('download-by-type') {
    my ($self, $c, $type, $subtype, @path) = @_;

    notFound($c, "You need to specify a type and a subtype in the URI.")
        unless defined $type && defined $subtype;

    (my $product) = $c->stash->{build}->buildproducts->search(
        {type => $type, subtype => $subtype}, {order_by => "productnr"});
    notFound($c, "Build doesn't have a build product with type $type/$subtype.")
        if !defined $product;

    $c->res->redirect(defaultUriForProduct($self, $c, $product, @path));
}


sub contents : Chained('build') PathPart Args(1) {
    my ($self, $c, $productnr) = @_;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    notFound($c, "Build doesn't have a product $productnr.") if !defined $product;

    my $path = $product->path;

    checkPath($self, $c, $path);

    notFound($c, "Product $path has disappeared.") unless -e $path;

    my $res;

    if ($product->type eq "nix-build" && -d $path) {
        $res = `cd $path && find . -print0 | xargs -0 ls -ld --`;
        error($c, "`ls -lR' error: $?") if $? != 0;

        my $baseuri = $c->uri_for('/build', $c->stash->{build}->id, 'download', $product->productnr);
        $baseuri .= "/".$product->name if $product->name;
        $res =~ s/(\.\/)($relPathRE)/<a href="$baseuri\/$2">$1$2<\/a>/g;
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

    elsif ($path =~ /\.(tar(\.gz|\.bz2|\.xz|\.lzma)?|tgz)$/ ) {
        $res = `tar tvfa "$path"`;
        error($c, "`tar' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.(zip|jar)$/ ) {
        $res = `unzip -v "$path"`;
        error($c, "`unzip' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.iso$/ ) {
        $res = `isoinfo -d -i "$path" && isoinfo -l -R -i "$path"`;
        error($c, "`isoinfo' error: $?") if $? != 0;
    }

    else {
        error($c, "Unsupported file type.");
    }

    die unless $res;

    $c->stash->{title} = "Contents of ".$product->path;
    $c->stash->{contents} = "<pre>$res</pre>";
    $c->stash->{template} = 'plain.tt';
}


sub getDependencyGraph {
    my ($self, $c, $runtime, $done, $path) = @_;
    my $node = $$done{$path};

    if (!defined $node) {
        $path =~ /\/[a-z0-9]+-(.*)$/;
        my $name = $1 // $path;
        $name =~ s/\.drv$//;
        $node =
            { path => $path
            , name => $name
            , buildStep => $runtime
                ? findBuildStepByOutPath($self, $c, $path, 0)
                : findBuildStepByDrvPath($self, $c, $path, 0)
            };
        $$done{$path} = $node;
        my @refs;
        foreach my $ref (queryReferences($path)) {
            next if $ref eq $path;
            next unless $runtime || $ref =~ /\.drv$/;
            getDependencyGraph($self, $c, $runtime, $done, $ref);
            push @refs, $ref;
        }
        # Show in reverse topological order to flatten the graph.
        # Should probably do a proper BFS.
        my @sorted = reverse topoSortPaths(@refs);
        $node->{refs} = [map { $$done{$_} } @sorted];
    }

    return $node;
}


sub build_deps : Chained('build') PathPart('build-deps') {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    my $drvPath = $build->drvpath;

    error($c, "Derivation no longer available.") unless isValidPath $drvPath;

    $c->stash->{buildTimeGraph} = getDependencyGraph($self, $c, 0, {}, $drvPath);

    $c->stash->{template} = 'build-deps.tt';
}


sub runtime_deps : Chained('build') PathPart('runtime-deps') {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    my @outPaths = map { $_->path } $build->buildoutputs->all;

    error($c, "Build outputs no longer available.") unless all { isValidPath($_) } @outPaths;

    my $done = {};
    $c->stash->{runtimeGraph} = [ map { getDependencyGraph($self, $c, 1, $done, $_) } @outPaths ];

    $c->stash->{template} = 'runtime-deps.tt';
}


sub nix : Chained('build') PathPart('nix') CaptureArgs(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    notFound($c, "Build cannot be downloaded as a closure or Nix package.")
        if $build->buildproducts->search({type => "nix-build"})->count == 0;

    foreach my $out ($build->buildoutputs) {
        notFound($c, "Path " . $out->path . " is no longer available.")
            unless isValidPath($out->path);
    }

    $c->stash->{channelBuilds} = $c->model('DB::Builds')->search(
        { id => $build->id },
        { join => ["buildoutputs"]
        , '+select' => ['buildoutputs.path', 'buildoutputs.name'], '+as' => ['outpath', 'outname'] });
}


sub restart : Chained('build') PathPart Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    my $drvpath = $build->drvpath;
    error($c, "This build cannot be restarted.")
        unless $build->finished && -f $drvpath;

    restartBuild($c->model('DB')->schema, $build);

    $c->flash->{buildMsg} = "Build has been restarted.";

    $c->res->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


sub cancel : Chained('build') PathPart Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    txn_do($c->model('DB')->schema, sub {
        error($c, "This build cannot be cancelled.")
            if $build->finished || $build->busy;

        # !!! Actually, it would be nice to be able to cancel busy
        # builds as well, but we would have to send a signal or
        # something to the build process.

        $build->update(
            { finished => 1, busy => 0, timestamp => time
            , iscachedbuild => 0, buildstatus => 4 # = cancelled
            });
    });

    $c->flash->{buildMsg} = "Build has been cancelled.";

    $c->res->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


sub keep : Chained('build') PathPart Args(1) {
    my ($self, $c, $x) = @_;
    my $keep = $x eq "1" ? 1 : 0;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    if ($keep) {
        registerRoot $_->path foreach $build->buildoutputs;
    }

    txn_do($c->model('DB')->schema, sub {
        $build->update({keep => $keep});
    });

    $c->flash->{buildMsg} =
        $keep ? "Build will be kept." : "Build will not be kept.";

    $c->res->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


sub add_to_release : Chained('build') PathPart('add-to-release') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    my $releaseName = trim $c->request->params->{name};

    my $release = $build->project->releases->find({name => $releaseName});

    error($c, "This project has no release named `$releaseName'.") unless $release;

    error($c, "This build is already a part of release `$releaseName'.")
        if $release->releasemembers->find({build => $build->id});

    foreach my $output ($build->buildoutputs) {
        error($c, "This build is no longer available.") unless isValidPath $output->path;
        registerRoot $output->path;
    }

    $release->releasemembers->create({build => $build->id, description => $build->description});

    $c->flash->{buildMsg} = "Build added to project <tt>$releaseName</tt>.";

    $c->res->redirect($c->uri_for($self->action_for("view_build"), $c->req->captures));
}


sub clone : Chained('build') PathPart('clone') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    $c->stash->{template} = 'clone-build.tt';
}


sub clone_submit : Chained('build') PathPart('clone/submit') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project);

    my ($nixExprPath, $nixExprInputName) = Hydra::Controller::Jobset::nixExprPathFromParams $c;

    # When the expression is in a .scm file, assume it's a Guile + Guix
    # build expression.
    my $exprType =
        $c->request->params->{"nixexprpath"} =~ /.scm$/ ? "guile" : "nix";

    my $jobName = trim $c->request->params->{"jobname"};
    error($c, "Invalid job name: $jobName") if $jobName !~ /^$jobNameRE$/;

    my $inputInfo = {};

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^input-(\w+)-name$/;
        my $baseName = $1;
        my ($inputName, $inputType) =
            Hydra::Controller::Jobset::checkInput($c, $baseName);
        my $inputValue = Hydra::Controller::Jobset::checkInputValue(
            $c, $inputType, $c->request->params->{"input-$baseName-value"});
        eval {
            # !!! fetchInput can take a long time, which might cause
            # the current HTTP request to time out.  So maybe this
            # should be done asynchronously.  But then error reporting
            # becomes harder.
            my $info = fetchInput(
                $c->model('DB'), $build->project, $build->jobset,
                $inputName, $inputType, $inputValue);
            push @{$$inputInfo{$inputName}}, $info if defined $info;
        };
        error($c, $@) if $@;
    }

    my ($jobs, $nixExprInput) = evalJobs($inputInfo, $exprType, $nixExprInputName, $nixExprPath);

    my $job;
    foreach my $j (@{$jobs->{job}}) {
        print STDERR $j->{jobName}, "\n";
        if ($j->{jobName} eq $jobName) {
            error($c, "Nix expression returned multiple builds for job $jobName.")
                if $job;
            $job = $j;
        }
    }

    error($c, "Nix expression did not return a job named $jobName.") unless $job;

    my %currentBuilds;
    my $newBuild = checkBuild(
        $c->model('DB'), $build->project, $build->jobset,
        $inputInfo, $nixExprInput, $job, \%currentBuilds, undef, {});

    error($c, "This build has already been performed.") unless $newBuild;

    $c->flash->{buildMsg} = "Build " . $newBuild->id . " added to the queue.";

    $c->res->redirect($c->uri_for($c->controller('Root')->action_for('queue')));
}


sub get_info : Chained('build') PathPart('api/get-info') Args(0) {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    # !!! strip the json prefix
    $c->stash->{jsonBuildId} = $build->id;
    $c->stash->{jsonDrvPath} = $build->drvpath;
    my $out = getMainOutput($build);
    $c->stash->{jsonOutPath} = $out->path if defined $out;
    $c->forward('View::JSON');
}


sub get_info : Chained('build') PathPart('evals') Args(0) {
    my ($self, $c) = @_;

    $c->stash->{template} = 'evals.tt';

    my $page = int($c->req->param('page') || "1") || 1;

    my $resultsPerPage = 20;

    my $evals = $c->stash->{build}->jobsetevals;

    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{total} = $evals->search({hasnewbuilds => 1})->count;
    $c->stash->{evals} = getEvals($self, $c, $evals, ($page - 1) * $resultsPerPage, $resultsPerPage)
}


1;

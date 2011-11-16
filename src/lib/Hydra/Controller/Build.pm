package Hydra::Controller::Build;

use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use Hydra::Helper::AddBuilds;
use File::stat;
use Data::Dump qw(dump);
use Nix;


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


sub view_build : Chained('build') PathPart('') Args(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};
    
    $c->stash->{template} = 'build.tt';
    $c->stash->{available} = isValidPath $build->outpath;
    $c->stash->{drvAvailable} = isValidPath $build->drvpath;
    $c->stash->{flashMsg} = $c->flash->{buildMsg};

    my $pathHash = $c->stash->{available} ? Nix::queryPathHash($build->outpath) : "Not available";
    $c->stash->{pathHash} = $pathHash;

    if (!$build->finished && $build->schedulingInfo->busy) {
        my $logfile = $build->schedulingInfo->logfile;
        $c->stash->{logtext} = `cat $logfile` if defined $logfile && -e $logfile;
    }

    if (defined $build->resultInfo && $build->resultInfo->iscachedbuild) {
        (my $cachedBuildStep) = $c->model('DB::BuildSteps')->search({ outpath => $build->outpath }, {}) ;
        $c->stash->{cachedBuild} = $cachedBuildStep->build if defined $cachedBuildStep;
    }
    
    (my $lastBuildStep) = $build->buildsteps->search({},{order_by => "stepnr DESC", rows => 1});
    my $path = defined $lastBuildStep ? $lastBuildStep->logfile : "" ;
    if (defined $build->resultInfo && ($build->resultInfo->buildstatus == 1 || $build->resultInfo->buildstatus == 6) && !($path eq "") && -f $lastBuildStep->logfile) {
	my $logtext = `tail -n 50 $path`;
        $c->stash->{logtext} = removeAsciiEscapes($logtext);
    }

    if($build->finished) {
        $c->stash->{prevBuilds} = [joinWithResultInfo($c, $c->model('DB::Builds'))->search(
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

    my $fallbackpath = -f $path ? $path : "$path.bz2";

    notFound($c, "Log file $path no longer exists.") unless -f $fallbackpath;
    $path = $fallbackpath;

    my $pipestart = ($path =~ /.bz2$/ ? "cat $path | bzip2 -d" : "cat $path") ; 

    if (!$mode) {
        # !!! quick hack
        my $pipeline = $pipestart
            . " | nix-log2xml | xsltproc " . $c->path_to("xsl/mark-errors.xsl") . " -"
            . " | xsltproc " . $c->path_to("xsl/log2html.xsl") . " - | tail -n +2";

        $c->stash->{template} = 'log.tt';
        $c->stash->{logtext} = `$pipeline`;
    }

    elsif ($mode eq "raw") {
        $c->stash->{'plain'} = { data => (scalar `$pipestart`) || " " };
        $c->forward('Hydra::View::Plain');
    }

    elsif ($mode eq "tail-reload") {
    	my $url = $c->request->uri->as_string;
    	$url =~ s/tail-reload/tail/g;
        $c->stash->{url} = $url;
        $c->stash->{reload} = defined $c->stash->{build}->schedulingInfo && $c->stash->{build}->schedulingInfo->busy;
        $c->stash->{title} = "";
        $c->stash->{contents} = (scalar `$pipestart | tail -n 50`) || " ";
        $c->stash->{template} = 'plain-reload.tt';
    }

    elsif ($mode eq "tail") {
        $c->stash->{'plain'} = { data => (scalar `$pipestart | tail -n 50`) || " " };
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


sub download : Chained('build') PathPart {
    my ($self, $c, $productnr, @path) = @_;

    $productnr = 1 if !defined $productnr;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    notFound($c, "Build doesn't have a product #$productnr.") if !defined $product;

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


sub runtimedeps : Chained('build') PathPart('runtime-deps') {
    my ($self, $c) = @_;
    
    my $build = $c->stash->{build};
    
    notFound($c, "Path " . $build->outpath . " is no longer available.")
        unless isValidPath($build->outpath);
    
    $c->stash->{current_view} = 'NixDepGraph';
    $c->stash->{storePaths} = [$build->outpath];
    
    $c->res->content_type('image/png'); # !!!
}


sub buildtimedeps : Chained('build') PathPart('buildtime-deps') {
    my ($self, $c) = @_;
    
    my $build = $c->stash->{build};
    
    notFound($c, "Path " . $build->drvpath . " is no longer available.")
        unless isValidPath($build->drvpath);
    
    $c->stash->{current_view} = 'NixDepGraph';
    $c->stash->{storePaths} = [$build->drvpath];
    
    $c->res->content_type('image/png'); # !!!
}


sub deps : Chained('build') PathPart('deps') {
    my ($self, $c) = @_;
    
    my $build = $c->stash->{build};
    $c->stash->{available} = isValidPath $build->outpath;
    $c->stash->{drvAvailable} = isValidPath $build->drvpath;

    my $drvpath = $build->drvpath;
    my $outpath = $build->outpath;
    
    my @buildtimepaths = ();
    my @buildtimedeps = ();
    @buildtimepaths = split '\n', `nix-store --query --requisites --include-outputs $drvpath` if isValidPath($build->drvpath);
    
    my @runtimepaths = ();
    my @runtimedeps = ();
    @runtimepaths = split '\n', `nix-store --query --requisites --include-outputs $outpath` if isValidPath($build->outpath);
    
    foreach my $p (@buildtimepaths) {
    	my $buildStep;
    	($buildStep) = $c->model('DB::BuildSteps')->search({ outpath => $p }, {}) ;
    	my %dep = ( buildstep => $buildStep,  path => $p ) ;
    	push(@buildtimedeps, \%dep);
    }

    foreach my $p (@runtimepaths) {
    	my $buildStep;
    	($buildStep) = $c->model('DB::BuildSteps')->search({ outpath => $p }, {}) ;
    	my %dep = ( buildstep => $buildStep,  path => $p ) ;
    	push(@runtimedeps, \%dep);
    }

    
    $c->stash->{buildtimedeps} = \@buildtimedeps;
    $c->stash->{runtimedeps} = \@runtimedeps;
    
    $c->stash->{template} = 'deps.tt';
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
    
    my $drvpath = $build->drvpath ;
    error($c, "This build cannot be restarted.")
        unless $build->finished && -f $drvpath ;

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

    txn_do($c->model('DB')->schema, sub {
        $build->resultInfo->update({keep => int $newStatus});
    });

    $c->flash->{buildMsg} =
        $newStatus == 0 ? "Build will not be kept." : "Build will be kept.";
    
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
 
    registerRoot $build->outpath;
    
    error($c, "This build is no longer available.") unless isValidPath $build->outpath;

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

    my ($jobs, $nixExprInput) = evalJobs($inputInfo, $nixExprInputName, $nixExprPath);

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
        $inputInfo, $nixExprInput, $job, \%currentBuilds);

    error($c, "This build has already been performed.") unless $newBuild;
    
    $c->flash->{buildMsg} = "Build " . $newBuild->id . " added to the queue.";
    
    $c->res->redirect($c->uri_for($c->controller('Root')->action_for('queue')));
}


sub get_info  : Chained('build') PathPart('api/get-info') Args(0) {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    # !!! strip the json prefix
    $c->stash->{jsonBuildId} = $build->id;
    $c->stash->{jsonDrvPath} = $build->drvpath;
    $c->stash->{jsonOutPath} = $build->outpath;
    $c->forward('View::JSON');
}


1;

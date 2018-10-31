package Hydra::Controller::Build;

use utf8;
use strict;
use warnings;
use base 'Hydra::Base::Controller::NixChannel';
use Hydra::Helper::Nix;
use Hydra::Helper::CatalystUtils;
use File::Basename;
use File::stat;
use File::Slurp;
use Data::Dump qw(dump);
use Nix::Store;
use Nix::Config;
use List::MoreUtils qw(all);
use Encode;
use MIME::Types;
use JSON::PP;


sub buildChain :Chained('/') :PathPart('build') :CaptureArgs(1) {
    my ($self, $c, $id) = @_;

    $id =~ /^[0-9]+$/ or error($c, "Invalid build ID ‘$id’.");

    $c->stash->{id} = $id;

    $c->stash->{build} = getBuild($c, $id);

    notFound($c, "Build with ID $id doesn't exist.")
        if !defined $c->stash->{build};

    $c->stash->{prevBuild} = getPreviousBuild($c->stash->{build});
    $c->stash->{prevSuccessfulBuild} = getPreviousSuccessfulBuild($c, $c->stash->{build});
    $c->stash->{firstBrokenBuild} = getNextBuild($c, $c->stash->{prevSuccessfulBuild});

    $c->stash->{mappers} = [$c->model('DB::UriRevMapper')->all];

    $c->stash->{project} = $c->stash->{build}->project;
    $c->stash->{jobset} = $c->stash->{build}->jobset;
    $c->stash->{job} = $c->stash->{build}->job;
}


sub findBuildStepByOutPath {
    my ($self, $c, $path) = @_;
    return $c->model('DB::BuildSteps')->search(
        { path => $path, busy => 0 },
        { join => ["buildstepoutputs"], order_by => ["status", "stopTime"], rows => 1 })->single;
}


sub findBuildStepByDrvPath {
    my ($self, $c, $drvPath) = @_;
    return $c->model('DB::BuildSteps')->search(
        { drvpath => $drvPath, busy => 0 },
        { order_by => ["status", "stopTime"], rows => 1 })->single;
}


sub build :Chained('buildChain') :PathPart('') :Args(0) :ActionClass('REST') { }

sub build_GET {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    $c->stash->{template} = 'build.tt';
    $c->stash->{isLocalStore} = isLocalStore();
    $c->stash->{available} =
        $c->stash->{isLocalStore}
        ? all { isValidPath($_->path) } $build->buildoutputs->all
        : 1;
    $c->stash->{drvAvailable} = isValidPath $build->drvpath;

    if ($build->finished && $build->iscachedbuild) {
        my $path = ($build->buildoutputs)[0]->path or die;
        my $cachedBuildStep = findBuildStepByOutPath($self, $c, $path);
        if (defined $cachedBuildStep) {
            $c->stash->{cachedBuild} = $cachedBuildStep->build;
            $c->stash->{cachedBuildStep} = $cachedBuildStep;
        }
    }

    if ($build->finished) {
        $c->stash->{prevBuilds} = [$c->model('DB::Builds')->search(
            { project => $c->stash->{project}->name
            , jobset => $c->stash->{jobset}->name
            , job => $c->stash->{job}->name
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
    ($c->stash->{nrEvals}) = $build->jobsetevals->search({ hasnewbuilds => 1 })->count;
    $c->stash->{eval} = getFirstEval($build);
    $self->status_ok(
        $c,
        entity => $build
    );

    if (defined $c->stash->{eval}) {
        my ($eval2) = $c->stash->{eval}->jobset->jobsetevals->search(
            { hasnewbuilds => 1, id => { '<', $c->stash->{eval}->id } },
            { order_by => "id DESC", rows => 1 });
        $c->stash->{otherEval} = $eval2 if defined $eval2;
    }

    # If this is an aggregate build, get its constituents.
    $c->stash->{constituents} = [$build->constituents_->search({}, {order_by => ["job"]})];

    $c->stash->{steps} = [$build->buildsteps->search({}, {order_by => "stepnr desc"})];

    $c->stash->{binaryCachePublicUri} = $c->config->{binary_cache_public_uri};
}


sub view_nixlog : Chained('buildChain') PathPart('nixlog') {
    my ($self, $c, $stepnr, $mode) = @_;

    my $step = $c->stash->{build}->buildsteps->find({stepnr => $stepnr});
    notFound($c, "Build doesn't have a build step $stepnr.") if !defined $step;

    $c->stash->{step} = $step;

    showLog($c, $mode, $step->busy == 0, $step->drvpath);
}


sub view_log : Chained('buildChain') PathPart('log') {
    my ($self, $c, $mode) = @_;
    showLog($c, $mode, $c->stash->{build}->finished,
            $c->stash->{build}->drvpath);
}


sub showLog {
    my ($c, $mode, $finished, $drvPath) = @_;
    $mode //= "pretty";

    my $log_uri = $c->uri_for($c->controller('Root')->action_for("log"), [basename($drvPath)]);

    if ($mode eq "pretty") {
        $c->stash->{log_uri} = $log_uri;
        $c->stash->{template} = 'log.tt';
    }

    elsif ($mode eq "raw") {
        $c->res->redirect($log_uri);
    }

    elsif ($mode eq "tail") {
        my $lines = 50;
        $c->stash->{log_uri} = $log_uri . "?tail=$lines";
        $c->stash->{tail} = $lines;
        $c->stash->{template} = 'log.tt';
    }

    else {
        error($c, "Unknown log display mode '$mode'.");
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
    my $p = pathIsInsidePrefix($path, $Nix::Config::storeDir);
    error($c, "Build product refers outside of the Nix store.") unless defined $p;
    return $p;
}


sub serveFile {
    my ($c, $path) = @_;

    my $res = run(cmd => ["nix", "ls-store", "--store", getStoreUri(), "--json", "$path"]);

    if ($res->{status}) {
        notFound($c, "File '$path' does not exist.") if $res->{stderr} =~ /does not exist/;
        die "$res->{stderr}\n";
    }

    my $ls = decode_json($res->{stdout});

    if ($ls->{type} eq "directory" && substr($c->request->uri, -1) ne "/") {
        return $c->res->redirect($c->request->uri . "/");
    }

    elsif ($ls->{type} eq "directory" && defined $ls->{entries}->{"index.html"}) {
        return serveFile($c, "$path/index.html");
    }

    elsif ($ls->{type} eq "symlink") {
        my $target = $ls->{target};
        return serveFile($c, substr($target, 0, 1) eq "/" ? $target : dirname($path) . "/" . $target);
    }

    elsif ($ls->{type} eq "regular") {

        $c->stash->{'plain'} = { data => grab(cmd => ["nix", "cat-store", "--store", getStoreUri(), "$path"]) };

        # Detect MIME type. Borrowed from Catalyst::Plugin::Static::Simple.
        my $type = "text/plain";
        if ($path =~ /.*\.(\S{1,})$/xms) {
            my $ext = $1;
            my $mimeTypes = MIME::Types->new(only_complete => 1);
            my $t = $mimeTypes->mimeTypeOf($ext);
            $type = ref $t ? $t->type : $t if $t;
        }
        $c->response->content_type($type);
        $c->forward('Hydra::View::Plain');
    }

    else {
        error($c, "Do not know how to serve path '$path'.");
    }
}


sub download : Chained('buildChain') PathPart {
    my ($self, $c, $productRef, @path) = @_;

    $productRef = 1 if !defined $productRef;

    my $product;
    if ($productRef =~ /^[0-9]+$/) {
        $product = $c->stash->{build}->buildproducts->find({productnr => $productRef});
    } else {
        $product = $c->stash->{build}->buildproducts->find({name => $productRef});
        @path = ($productRef, @path);
    }
    notFound($c, "Build doesn't have a product $productRef.") if !defined $product;

    if ($product->path !~ /^($Nix::Config::storeDir\/[^\/]+)/) {
        die "Invalid store path '" . $product->path . "'.\n";
    }
    my $storePath = $1;

    return $c->res->redirect(defaultUriForProduct($self, $c, $product, @path))
        if scalar @path == 0 && ($product->name || $product->defaultpath);

    # If the product has a name, then the first path element can be
    # ignored (it's the name included in the URL for informational purposes).
    shift @path if $product->name;

    # Security paranoia.
    foreach my $elem (@path) {
        error($c, "Invalid filename '$elem'.") if $elem !~ /^$pathCompRE$/;
    }

    my $path = $product->path;
    $path .= "/" . join("/", @path) if scalar @path > 0;

    if (isLocalStore) {

        notFound($c, "File '" . $product->path . "' does not exist.") unless -e $product->path;

        # Make sure the file is in the Nix store.
        $path = checkPath($self, $c, $path);

        # If this is a directory but no "/" is attached, then redirect.
        if (-d $path && substr($c->request->uri, -1) ne "/") {
            return $c->res->redirect($c->request->uri . "/");
        }

        $path = "$path/index.html" if -d $path && -e "$path/index.html";

        notFound($c, "File '$path' does not exist.") if !-e $path;

        notFound($c, "Path '$path' is a directory.") if -d $path;

        $c->serve_static_file($path);

    } else {
        serveFile($c, $path);
    }

    $c->response->headers->last_modified($c->stash->{build}->stoptime);
}


sub output : Chained('buildChain') PathPart Args(1) {
    my ($self, $c, $outputName) = @_;
    my $build = $c->stash->{build};

    error($c, "This build is not finished yet.") unless $build->finished;
    my $output = $build->buildoutputs->find({name => $outputName});
    notFound($c, "This build has no output named ‘$outputName’") unless defined $output;
    gone($c, "Output is no longer available.") unless isValidPath $output->path;

    $c->response->header('Content-Disposition', "attachment; filename=\"build-${\$build->id}-${\$outputName}.nar.bz2\"");
    $c->stash->{current_view} = 'NixNAR';
    $c->stash->{storePath} = $output->path;
}


# Redirect to a download with the given type.  Useful when you want to
# link to some build product of the latest build (i.e. in conjunction
# with the .../latest redirect).
sub download_by_type : Chained('buildChain') PathPart('download-by-type') {
    my ($self, $c, $type, $subtype, @path) = @_;

    notFound($c, "You need to specify a type and a subtype in the URI.")
        unless defined $type && defined $subtype;

    (my $product) = $c->stash->{build}->buildproducts->search(
        {type => $type, subtype => $subtype}, {order_by => "productnr"});
    notFound($c, "Build doesn't have a build product with type $type/$subtype.")
        if !defined $product;

    $c->res->redirect(defaultUriForProduct($self, $c, $product, @path));
}


sub contents : Chained('buildChain') PathPart Args(1) {
    my ($self, $c, $productnr) = @_;

    my $product = $c->stash->{build}->buildproducts->find({productnr => $productnr});
    notFound($c, "Build doesn't have a product $productnr.") if !defined $product;

    my $path = $product->path;

    $path = checkPath($self, $c, $path);

    notFound($c, "Product $path has disappeared.") unless -e $path;

    # Sanitize $path to prevent shell injection attacks.
    $path =~ /^\/[\/[A-Za-z0-9_\-\.=+:]+$/ or die "Filename contains illegal characters.\n";

    # FIXME: don't use shell invocations below.

    # FIXME: use nix cat-store

    my $res;

    if ($product->type eq "nix-build" && -d $path) {
        # FIXME: use nix ls-store -R --json
        $res = `cd '$path' && find . -print0 | xargs -0 ls -ld --`;
        error($c, "`ls -lR' error: $?") if $? != 0;

        #my $baseuri = $c->uri_for('/build', $c->stash->{build}->id, 'download', $product->productnr);
        #$baseuri .= "/".$product->name if $product->name;
        #$res =~ s/(\.\/)($relPathRE)/<a href="$baseuri\/$2">$1$2<\/a>/g;
    }

    elsif ($path =~ /\.rpm$/) {
        $res = `rpm --query --info --package '$path'`;
        error($c, "RPM error: $?") if $? != 0;
        $res .= "===\n";
        $res .= `rpm --query --list --verbose --package '$path'`;
        error($c, "RPM error: $?") if $? != 0;
    }

    elsif ($path =~ /\.deb$/) {
        $res = `dpkg-deb --info '$path'`;
        error($c, "`dpkg-deb' error: $?") if $? != 0;
        $res .= "===\n";
        $res .= `dpkg-deb --contents '$path'`;
        error($c, "`dpkg-deb' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.(tar(\.gz|\.bz2|\.xz|\.lzma)?|tgz)$/ ) {
        $res = `tar tvfa '$path'`;
        error($c, "`tar' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.(zip|jar)$/ ) {
        $res = `unzip -v '$path'`;
        error($c, "`unzip' error: $?") if $? != 0;
    }

    elsif ($path =~ /\.iso$/ ) {
        $res = `isoinfo -d -i '$path' && isoinfo -l -R -i '$path'`;
        error($c, "`isoinfo' error: $?") if $? != 0;
    }

    else {
        error($c, "Unsupported file type.");
    }

    die unless $res;

    $c->stash->{title} = "Contents of ".$product->path;
    $c->stash->{contents} = decode("utf-8", $res);
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
                ? findBuildStepByOutPath($self, $c, $path)
                : findBuildStepByDrvPath($self, $c, $path)
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


sub build_deps : Chained('buildChain') PathPart('build-deps') {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    my $drvPath = $build->drvpath;

    error($c, "Derivation no longer available.") unless isValidPath $drvPath;

    $c->stash->{buildTimeGraph} = getDependencyGraph($self, $c, 0, {}, $drvPath);

    $c->stash->{template} = 'build-deps.tt';
}


sub runtime_deps : Chained('buildChain') PathPart('runtime-deps') {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    my @outPaths = map { $_->path } $build->buildoutputs->all;

    requireLocalStore($c);

    error($c, "Build outputs no longer available.") unless all { isValidPath($_) } @outPaths;

    my $done = {};
    $c->stash->{runtimeGraph} = [ map { getDependencyGraph($self, $c, 1, $done, $_) } @outPaths ];

    $c->stash->{template} = 'runtime-deps.tt';
}


sub nix : Chained('buildChain') PathPart('nix') CaptureArgs(0) {
    my ($self, $c) = @_;

    my $build = $c->stash->{build};

    notFound($c, "Build cannot be downloaded as a closure or Nix package.")
        if $build->buildproducts->search({type => "nix-build"})->count == 0;

    if (isLocalStore) {
        foreach my $out ($build->buildoutputs) {
            notFound($c, "Path " . $out->path . " is no longer available.")
                unless isValidPath($out->path);
        }
    }

    $c->stash->{channelBuilds} = $c->model('DB::Builds')->search(
        { id => $build->id },
        { join => ["buildoutputs"]
        , '+select' => ['buildoutputs.path', 'buildoutputs.name'], '+as' => ['outpath', 'outname'] });
}


sub restart : Chained('buildChain') PathPart Args(0) {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    requireRestartPrivileges($c, $build->project);
    my $n = restartBuilds($c->model('DB')->schema, $c->model('DB::Builds')->search({ id => $build->id }));
    error($c, "This build cannot be restarted.") if $n != 1;
    $c->flash->{successMsg} = "Build has been restarted.";
    $c->res->redirect($c->uri_for($self->action_for("build"), $c->req->captures));
}


sub cancel : Chained('buildChain') PathPart Args(0) {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    requireProjectOwner($c, $build->project);
    my $n = cancelBuilds($c->model('DB')->schema, $c->model('DB::Builds')->search({ id => $build->id }));
    error($c, "This build cannot be cancelled.") if $n != 1;
    $c->flash->{successMsg} = "Build has been cancelled.";
    $c->res->redirect($c->uri_for($self->action_for("build"), $c->req->captures));
}


sub keep : Chained('buildChain') PathPart Args(1) {
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

    $c->flash->{successMsg} =
        $keep ? "Build will be kept." : "Build will not be kept.";

    $c->res->redirect($c->uri_for($self->action_for("build"), $c->req->captures));
}


sub bump : Chained('buildChain') PathPart('bump') {
    my ($self, $c, $x) = @_;

    my $build = $c->stash->{build};

    requireProjectOwner($c, $build->project); # FIXME: require admin?

    $c->model('DB')->schema->txn_do(sub {
        $build->update({globalpriority => time()});
    });

    $c->flash->{successMsg} = "Build has been bumped to the front of the queue.";

    $c->res->redirect($c->uri_for($self->action_for("build"), $c->req->captures));
}


sub add_to_release : Chained('buildChain') PathPart('add-to-release') Args(0) {
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

    $c->flash->{successMsg} = "Build added to project <tt>$releaseName</tt>.";

    $c->res->redirect($c->uri_for($self->action_for("build"), $c->req->captures));
}


sub get_info : Chained('buildChain') PathPart('api/get-info') Args(0) {
    my ($self, $c) = @_;
    my $build = $c->stash->{build};
    $c->stash->{json}->{buildId} = $build->id;
    $c->stash->{json}->{drvPath} = $build->drvpath;
    my $out = getMainOutput($build);
    $c->stash->{json}->{outPath} = $out->path if defined $out;
    $c->forward('View::JSON');
}


sub evals : Chained('buildChain') PathPart('evals') Args(0) {
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


# Redirect to the latest finished evaluation that contains this build.
sub eval : Chained('buildChain') PathPart('eval') {
    my ($self, $c, @rest) = @_;

    my $eval = $c->stash->{build}->jobsetevals->find(
        { hasnewbuilds => 1 },
        { order_by => "id DESC", rows => 1
        , "not exists (select 1 from jobsetevalmembers m2 join builds b2 on me.eval = m2.eval and m2.build = b2.id and b2.finished = 0)"
        });

    notFound($c, "There is no finished evaluation containing this build.") unless defined $eval;

    $c->res->redirect($c->uri_for($c->controller('JobsetEval')->action_for("view"), [$eval->id], @rest, $c->req->params));
}


sub reproduce : Chained('buildChain') PathPart('reproduce') Args(0) {
    my ($self, $c) = @_;
    $c->response->content_type('text/x-shellscript');
    $c->response->header('Content-Disposition', 'attachment; filename="reproduce-build-' . $c->stash->{build}->id . '.sh"');
    $c->stash->{template} = 'reproduce.tt';
    $c->stash->{eval} = getFirstEval($c->stash->{build});
}


1;

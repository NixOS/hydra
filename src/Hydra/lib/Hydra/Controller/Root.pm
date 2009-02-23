package Hydra::Controller::Root;

use strict;
use warnings;
use parent 'Catalyst::Controller';
use Hydra::Helper::Nix;

#
# Sets the actions in this controller to be registered with no prefix
# so they function identically to actions created in MyApp.pm
#
__PACKAGE__->config->{namespace} = '';


# Security checking of filenames.
my $pathCompRE = "(?:[A-Za-z0-9-\+][A-Za-z0-9-\+\._]*)";
my $relPathRE = "(?:$pathCompRE(?:\/$pathCompRE)*)";


sub begin :Private {
    my ($self, $c) = @_;
    $c->stash->{projects} = [$c->model('DB::Projects')->search({}, {order_by => 'displayname'})];
    $c->stash->{curUri} = $c->request->uri;
}


sub error {
    my ($c, $msg) = @_;
    $c->stash->{template} = 'error.tt';
    $c->stash->{error} = $msg;
    $c->response->status(404);
}


sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}


sub getBuild {
    my ($c, $id) = @_;
    my $build = $c->model('DB::Builds')->find($id);
    return $build;
}


sub getBuildStats {
    my ($c, $builds) = @_;
    
    $c->stash->{finishedBuilds} = $builds->search({finished => 1}) || 0;
    
    $c->stash->{succeededBuilds} = $builds->search(
        {finished => 1, buildStatus => 0},
        {join => 'resultInfo'}) || 0;
        
    $c->stash->{scheduledBuilds} = $builds->search({finished => 0}) || 0;
        
    $c->stash->{busyBuilds} = $builds->search(
        {finished => 0, busy => 1},
        {join => 'schedulingInfo'}) || 0;
        
    $c->stash->{totalBuildTime} = $builds->search({},
        {join => 'resultInfo', select => {sum => 'stoptime - starttime'}, as => ['sum']})
        ->first->get_column('sum') || 0;
}


sub index :Path :Args(0) {
    my ($self, $c) = @_;
    $c->stash->{template} = 'index.tt';
    
    getBuildStats($c, $c->model('DB::Builds'));
}


sub login :Local {
    my ($self, $c) = @_;
    
    my $username = $c->request->params->{username} || "";
    my $password = $c->request->params->{password} || "";

    if ($username && $password) {
        if ($c->authenticate({username => $username, password => $password})) {
            $c->response->redirect(
                defined $c->flash->{afterLogin}
                ? $c->flash->{afterLogin}
                : $c->uri_for('/'));
            return;
        }
        $c->stash->{errorMsg} = "Bad username or password.";
    }
    
    $c->stash->{template} = 'login.tt';
}


sub logout :Local {
    my ($self, $c) = @_;
    $c->logout;
    $c->response->redirect($c->uri_for('/'));
}


sub requireLogin {
    my ($c) = @_;
    $c->flash->{afterLogin} = $c->request->uri;
    $c->response->redirect($c->uri_for('/login'));
}


sub queue :Local {
    my ($self, $c) = @_;
    $c->stash->{template} = 'queue.tt';
    $c->stash->{queue} = [$c->model('DB::Builds')->search(
        {finished => 0}, {join => 'schedulingInfo', order_by => ["priority DESC", "timestamp"]})];
}


sub showJobStatus {
    my ($c, $builds) = @_;
    $c->stash->{template} = 'jobstatus.tt';

    # Get the latest finished build for each unique job.
    $c->stash->{latestBuilds} = [$builds->search({},
        { join => 'resultInfo'
        , where => {
            finished => { "!=", 0 },
            timestamp => \ (
                "= (select max(timestamp) from Builds " .
                "where project == me.project and attrName == me.attrName and finished != 0 and system == me.system)"),
          }
        , order_by => "project, attrname, system"
        })];
}


sub jobstatus :Local {
    my ($self, $c) = @_;
    showJobStatus($c, $c->model('DB::Builds'));
}


sub showAllBuilds {
    my ($c, $baseUri, $page, $builds) = @_;
    $c->stash->{template} = 'all.tt';

    $page = (defined $page ? int($page) : 1) || 1;

    my $resultsPerPage = 50;

    my $nrBuilds = scalar($builds->search({finished => 1}));

    $c->stash->{baseUri} = $baseUri;
    $c->stash->{page} = $page;
    $c->stash->{resultsPerPage} = $resultsPerPage;
    $c->stash->{totalBuilds} = $nrBuilds;

    $c->stash->{builds} = [$builds->search(
        {finished => 1}, {order_by => "timestamp DESC", rows => $resultsPerPage, page => $page})];
}


sub all :Local {
    my ($self, $c, $page) = @_;
    showAllBuilds($c, $c->uri_for("/all"), $page, $c->model('DB::Builds'));
}


sub releasesets :Local {
    my ($self, $c, $projectName) = @_;
    $c->stash->{template} = 'releasesets.tt';

    my $project = $c->model('DB::Projects')->find($projectName);
    return error($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{curProject} = $project;

    $c->stash->{releaseSets} = [$project->releasesets->all];
}


sub getReleaseSet {
    my ($c, $projectName, $releaseSetName) = @_;
    
    my $project = $c->model('DB::Projects')->find($projectName);
    die "Project $projectName doesn't exist." if !defined $project;
    $c->stash->{curProject} = $project;

    (my $releaseSet) = $c->model('DB::ReleaseSets')->find($projectName, $releaseSetName);
    die "Release set $releaseSetName doesn't exist." if !defined $releaseSet;
    $c->stash->{releaseSet} = $releaseSet;

    (my $primaryJob) = $releaseSet->releasesetjobs->search({isprimary => 1});
    #die "Release set $releaseSetName doesn't have a primary job." if !defined $primaryJob;

    my $jobs = [$releaseSet->releasesetjobs->search({},
        {order_by => ["isprimary DESC", "job", "attrs"]})];

    $c->stash->{jobs} = $jobs;

    return ($project, $releaseSet, $primaryJob, $jobs);
}


sub updateReleaseSet {
    my ($c, $releaseSet) = @_;
    
    my $releaseSetName = trim $c->request->params->{name};
    die "Invalid release set name: $releaseSetName" unless $releaseSetName =~ /^[[:alpha:]]\w*$/;
    
    $releaseSet->name($releaseSetName);
    $releaseSet->description(trim $c->request->params->{description});
    $releaseSet->update;

    $releaseSet->releasesetjobs->delete_all;

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^job-(\d+)-name$/;
        my $baseName = $1;

        my $name = trim $c->request->params->{"job-$baseName-name"};
        my $description = trim $c->request->params->{"job-$baseName-description"};
        my $attrs = trim $c->request->params->{"job-$baseName-attrs"};

        die "Invalid job name: $name" unless $name =~ /^\w+$/;
        
        $releaseSet->releasesetjobs->create(
            { job => $name
            , description => $description
            , attrs => $attrs
            , isprimary => $c->request->params->{"primary"} eq $baseName ? 1 : 0
            });
    }

    die "There must be one primary job." if $releaseSet->releasesetjobs->search({isprimary => 1})->count != 1;
}


sub releases :Local {
    my ($self, $c, $projectName, $releaseSetName, $subcommand) = @_;

    my ($project, $releaseSet, $primaryJob, $jobs) = getReleaseSet($c, $projectName, $releaseSetName);

    if (defined $subcommand && $subcommand ne "") {

        return requireLogin($c) if !$c->user_exists;

        return error($c, "Only the project owner or the administrator can perform this operation.")
            unless $c->check_user_roles('admin') || $c->user->username eq $project->owner->username;

        if ($subcommand eq "edit") {
            $c->stash->{template} = 'edit-releaseset.tt';
            return;
        }

        elsif ($subcommand eq "submit") {
            $c->model('DB')->schema->txn_do(sub {
                updateReleaseSet($c, $releaseSet);
            });
            return $c->res->redirect($c->uri_for("/releases", $projectName, $releaseSet->name));
        }

        elsif ($subcommand eq "delete") {
            $c->model('DB')->schema->txn_do(sub {
                $releaseSet->delete;
            });
            return $c->res->redirect($c->uri_for("/releasesets", $projectName));
        }

        else { return error($c, "Unknown subcommand."); }
    }
    
    $c->stash->{template} = 'releases.tt';

    my @releases = ();
    push @releases, getRelease($_, $jobs) foreach getPrimaryBuildsForReleaseSet($project, $primaryJob);
    $c->stash->{releases} = [@releases];
}


sub create_releaseset :Local {
    my ($self, $c, $projectName, $subcommand) = @_;

    my $project = $c->model('DB::Projects')->find($projectName);
    die "Project $projectName doesn't exist." if !defined $project;
    $c->stash->{curProject} = $project;

    return requireLogin($c) if !$c->user_exists;

    return error($c, "Only the project owner or the administrator can perform this operation.")
        unless $c->check_user_roles('admin') || $c->user->username eq $project->owner->username;

    if (defined $subcommand && $subcommand eq "submit") {
        eval {
            my $releaseSetName = $c->request->params->{name};
            $c->model('DB')->schema->txn_do(sub {
                # Note: $releaseSetName is validated in updateProject,
                # which will abort the transaction if the name isn't
                # valid.
                my $releaseSet = $project->releasesets->create({name => $releaseSetName});
                updateReleaseSet($c, $releaseSet);
                return $c->res->redirect($c->uri_for("/releases", $projectName, $releaseSet->name));
            });
        };
        if ($@) {
            return error($c, $@);
        }
    }
    
    $c->stash->{template} = 'edit-releaseset.tt';
    $c->stash->{create} = 1;
}


sub release :Local {
    my ($self, $c, $projectName, $releaseSetName, $releaseId) = @_;
    $c->stash->{template} = 'release.tt';

    my ($project, $releaseSet, $primaryJob, $jobs) = getReleaseSet($c, $projectName, $releaseSetName);

    if ($releaseId eq "latest") {
        # Redirect to the latest successful release.
        my $latest = getLatestSuccessfulRelease($project, $primaryJob, $jobs);
        return error($c, "This release set has no successful releases yet.") if !defined $latest;
        return $c->res->redirect($c->uri_for("/release", $projectName, $releaseSetName, $latest->id));
    }
    
    # Note: we don't actually check whether $releaseId is a primary
    # build, but who cares?
    my $primaryBuild = $project->builds->find($releaseId,
        { join => 'resultInfo', '+select' => ["resultInfo.releasename"], '+as' => ["releasename"] });
    return error($c, "Release $releaseId doesn't exist.") if !defined $primaryBuild;
    
    $c->stash->{release} = getRelease($primaryBuild, $jobs);
}


sub updateProject {
    my ($c, $project) = @_;
    my $projectName = trim $c->request->params->{name};
    die "Invalid project name: $projectName" unless $projectName =~ /^[[:alpha:]]\w*$/;
    
    my $displayName = trim $c->request->params->{displayname};
    die "Invalid display name: $displayName" if $displayName eq "";
    
    $project->name($projectName);
    $project->displayname($displayName);
    $project->description(trim $c->request->params->{description});
    $project->homepage(trim $c->request->params->{homepage});
    $project->enabled(trim($c->request->params->{enabled}) eq "1" ? 1 : 0);

    if ($c->check_user_roles('admin')) {
        my $owner = trim $c->request->params->{owner};
        die "Invalid owner: $owner"
            unless defined $c->model('DB::Users')->find({username => $owner});
        $project->owner($owner);
    }

    $project->update;
    
    my %jobsetNames;

    foreach my $param (keys %{$c->request->params}) {
        next unless $param =~ /^jobset-(\w+)-name$/;
        my $baseName = $1;
        next if $baseName eq "template";

        my $jobsetName = trim $c->request->params->{"jobset-$baseName-name"};
        die "Invalid jobset name: $jobsetName" unless $jobsetName =~ /^[[:alpha:]]\w*$/;

        # The Nix expression path must be relative and can't contain ".." elements.
        my $nixExprPath = trim $c->request->params->{"jobset-$baseName-nixexprpath"};
        die "Invalid Nix expression path: $nixExprPath" if $nixExprPath !~ /^$relPathRE$/;

        my $nixExprInput = trim $c->request->params->{"jobset-$baseName-nixexprinput"};
        die "Invalid Nix expression input name: $nixExprInput" unless $nixExprInput =~ /^\w+$/;

        $jobsetNames{$jobsetName} = 1;

        my $jobset;

        my $description = trim $c->request->params->{"jobset-$baseName-description"};

        if ($baseName =~ /^\d+$/) { # numeric base name is auto-generated, i.e. a new entry
            $jobset = $project->jobsets->create(
                { name => $jobsetName
                , description => $description
                , nixexprpath => $nixExprPath
                , nixexprinput => $nixExprInput
                });
        } else { # it's an existing jobset
            $jobset = ($project->jobsets->search({name => $baseName}))[0];
            die unless defined $jobset;
            $jobset->name($jobsetName);
            $jobset->description($description);
            $jobset->nixexprpath($nixExprPath);
            $jobset->nixexprinput($nixExprInput);
            $jobset->update;
        }

        my %inputNames;
        
        # Process the inputs of this jobset.
        foreach my $param (keys %{$c->request->params}) {
            next unless $param =~ /^jobset-$baseName-input-(\w+)-name$/;
            my $baseName2 = $1;
            next if $baseName2 eq "template";
            print STDERR "GOT INPUT: $baseName2\n";

            my $inputName = trim $c->request->params->{"jobset-$baseName-input-$baseName2-name"};
            die "Invalid input name: $inputName" unless $inputName =~ /^[[:alpha:]]\w*$/;

            my $inputType = trim $c->request->params->{"jobset-$baseName-input-$baseName2-type"};
            die "Invalid input type: $inputType" unless
                $inputType eq "svn" || $inputType eq "cvs" || $inputType eq "tarball" ||
                $inputType eq "string" || $inputType eq "path" || $inputType eq "boolean";

            $inputNames{$inputName} = 1;
            
            my $input;
            if ($baseName2 =~ /^\d+$/) { # numeric base name is auto-generated, i.e. a new entry
                $input = $jobset->jobsetinputs->create(
                    { name => $inputName
                    , type => $inputType
                    });
            } else { # it's an existing jobset
                $input = ($jobset->jobsetinputs->search({name => $baseName2}))[0];
                die unless defined $input;
                $input->name($inputName);
                $input->type($inputType);
                $input->update;
            }

            # Update the values for this input.  Just delete all the
            # current ones, then create the new values.
            $input->jobsetinputalts->delete_all;
            my $values = $c->request->params->{"jobset-$baseName-input-$baseName2-values"};
            $values = [] unless defined $values;
            $values = [$values] unless ref($values) eq 'ARRAY';
            my $altnr = 0;
            foreach my $value (@{$values}) {
                print STDERR "VALUE: $value\n";
                my $value = trim $value;
                die "Invalid Boolean value: $value" if
                    $inputType eq "boolean" && !($value eq "true" || $value eq "false");
                $input->jobsetinputalts->create({altnr => $altnr++, value => $value});
            }
        }

        # Get rid of deleted inputs.
        my @inputs = $jobset->jobsetinputs->all;
        foreach my $input (@inputs) {
            $input->delete unless defined $inputNames{$input->name};
        }
    }

    # Get rid of deleted jobsets, i.e., ones that are no longer submitted in the parameters.
    my @jobsets = $project->jobsets->all;
    foreach my $jobset (@jobsets) {
        $jobset->delete unless defined $jobsetNames{$jobset->name};
    }
}


sub project :Local {
    my ($self, $c, $projectName, $subcommand, $arg) = @_;
    $c->stash->{template} = 'project.tt';
    
    my $project = $c->model('DB::Projects')->find($projectName);
    return error($c, "Project $projectName doesn't exist.") if !defined $project;

    my $isPosted = $c->request->method eq "POST";

    $c->stash->{curProject} = $project;
    
    $subcommand = "" unless defined $subcommand;

    if ($subcommand eq "jobstatus") {
        return showJobStatus($c, scalar $project->builds);
    }

    elsif ($subcommand eq "all") {
        return showAllBuilds($c, $c->uri_for("/project", $projectName, "all"),
            $arg, scalar $project->builds);
    }

    elsif ($subcommand ne "") {

        return requireLogin($c) if !$c->user_exists;

        return error($c, "Only the project owner or the administrator can perform this operation.")
            unless $c->check_user_roles('admin') || $c->user->username eq $project->owner->username;
        
        if ($subcommand eq "edit") {
            $c->stash->{edit} = 1;
        }

        elsif ($subcommand eq "submit" && $isPosted) {
            $c->model('DB')->schema->txn_do(sub {
                updateProject($c, $project);
            });
            return $c->res->redirect($c->uri_for("/project", $project->name));
        }

        elsif ($subcommand eq "delete" && $isPosted) {
            $c->model('DB')->schema->txn_do(sub {
                $project->delete;
            });
            return $c->res->redirect($c->uri_for("/"));
        }

        else {
            return error($c, "Unknown subcommand $subcommand.");
        }
    }

    getBuildStats($c, scalar $project->builds);
    
    $c->stash->{jobNames} =
        [$c->model('DB::Builds')->search({project => $projectName}, {select => [{distinct => 'attrname'}], as => ['attrname']})];
}


sub createproject :Local {
    my ($self, $c, $subcommand) = @_;

    return requireLogin($c) if !$c->user_exists;

    return error($c, "Only administrators can create projects.")
        unless $c->check_user_roles('admin');

    if (defined $subcommand && $subcommand eq "submit") {
        eval {
            my $projectName = trim $c->request->params->{name};
            $c->model('DB')->schema->txn_do(sub {
                # Note: $projectName is validated in updateProject,
                # which will abort the transaction if the name isn't
                # valid.  Idem for the owner.
                my $project = $c->model('DB::Projects')->create(
                    {name => $projectName, displayname => "", owner => trim $c->request->params->{owner}});
                updateProject($c, $project);
            });
            return $c->res->redirect($c->uri_for("/project", $projectName));
        };
        if ($@) {
            return error($c, $@);
        }
    }
    
    $c->stash->{template} = 'project.tt';
    $c->stash->{create} = 1;
    $c->stash->{edit} = 1;
}


sub job :Local {
    my ($self, $c, $projectName, $jobName) = @_;
    $c->stash->{template} = 'job.tt';

    my $project = $c->model('DB::Projects')->find($projectName);
    return error($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{curProject} = $project;

    $c->stash->{jobName} = $jobName;
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        {finished => 1, project => $projectName, attrName => $jobName},
        {order_by => "timestamp DESC"})];
}


sub default :Path {
    my ($self, $c) = @_;
    error($c, "Page not found.");
}


sub build :Local {
    my ($self, $c, $id) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    $c->stash->{curProject} = $build->project;

    $c->stash->{template} = 'build.tt';
    $c->stash->{build} = $build;
    $c->stash->{id} = $id;

    $c->stash->{curTime} = time;

    $c->stash->{available} = isValidPath $build->outpath;

    if (!$build->finished && $build->schedulingInfo->busy) {
        my $logfile = $build->schedulingInfo->logfile;
        $c->stash->{logtext} = `cat $logfile`;
    }
}


sub log :Local {
    my ($self, $c, $id) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build $id doesn't exist.") if !defined $build;

    return error($c, "Build $id didn't produce a log.") if !defined $build->resultInfo->logfile;

    $c->stash->{template} = 'log.tt';
    $c->stash->{build} = $build;

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($c, $build->resultInfo->logfile);
}


sub nixlog :Local {
    my ($self, $c, $id, $stepnr) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    my $step = $build->buildsteps->find({stepnr => $stepnr});
    return error($c, "Build $id doesn't have a build step $stepnr.") if !defined $step;

    return error($c, "Build step $stepnr of build $id does not have a log file.") if $step->logfile eq "";
    
    $c->stash->{template} = 'log.tt';
    $c->stash->{build} = $build;
    $c->stash->{step} = $step;

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($c, $step->logfile);
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


sub download :Local {
    my ($self, $c, $id, $productnr, $filename, @path) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    my $product = $build->buildproducts->find({productnr => $productnr});
    return error($c, "Build $id doesn't have a product $productnr.") if !defined $product;

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


sub closure :Local {
    my ($self, $c, $buildId) = @_;

    my $build = getBuild($c, $buildId);
    return error($c, "Build $buildId doesn't exist.") if !defined $build;

    return error($c, "Build $buildId cannot be downloaded as a closure.")
        if !$build->buildproducts->find({type => "nix-build"});

    return error($c, "Path " . $build->outpath . " is no longer available.") unless isValidPath($build->outpath);

    $c->stash->{current_view} = 'Hydra::View::NixClosure';
    $c->stash->{storePath} = $build->outpath;
    $c->stash->{name} = $build->nixname;

    # !!! quick hack; this is to make HEAD requests return the right
    # MIME type.  This is set in the view as well, but the view isn't
    # called for HEAD requests.  There should be a cleaner solution...
    $c->response->content_type('application/x-nix-export');
    $c->response->header('Content-Disposition' => 'attachment; filename=' . $c->stash->{name} . '.closure.gz');
}


sub manifest :Local {
    my ($self, $c, $buildId) = @_;

    my $build = getBuild($c, $buildId);
    return error($c, "Build with ID $buildId doesn't exist.") if !defined $build;
    return error($c, "Path " . $build->outpath . " is no longer available.") unless isValidPath($build->outpath);
    
    $c->stash->{current_view} = 'Hydra::View::NixManifest';
    $c->stash->{storePath} = $build->outpath;
}


sub nar :Local {
    my ($self, $c, @rest) = @_;

    my $path .= "/" . join("/", @rest);

    return error($c, "Path " . $path . " is no longer available.") unless isValidPath($path);

    $c->stash->{current_view} = 'Hydra::View::NixNAR';
    $c->stash->{storePath} = $path;
}


sub end : ActionClass('RenderView') {}


1;

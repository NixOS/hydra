package HydraFrontend::Controller::Root;

use strict;
use warnings;
use parent 'Catalyst::Controller';
use HydraFrontend::Helper::Nix;

#
# Sets the actions in this controller to be registered with no prefix
# so they function identically to actions created in MyApp.pm
#
__PACKAGE__->config->{namespace} = '';


# Security checking of filenames.
my $pathCompRE = "(?:[A-Za-z0-9-\+][A-Za-z0-9-\+\._]*)";
my $relPathRE = "(?:$pathCompRE(?:\/$pathCompRE)*)";


sub begin :Private {
    my ( $self, $c ) = @_;
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
    (my $build) = $c->model('DB::Builds')->search({ id => $id });
    return $build;
}


sub index :Path :Args(0) {
    my ( $self, $c ) = @_;
    $c->stash->{template} = 'index.tt';
    $c->stash->{scheduled} = [$c->model('DB::Builds')->search(
        {finished => 0}, {join => 'schedulingInfo'})]; # !!!
    $c->stash->{allBuilds} = [$c->model('DB::Builds')->search(
        {finished => 1}, {order_by => "timestamp DESC"})];
    # Get the latest finished build for each unique job.
    $c->stash->{latestBuilds} = [$c->model('DB::Builds')->search(undef,
        { join => 'resultInfo'
        , where => "finished != 0 and timestamp = (select max(timestamp) from Builds where project == me.project and attrName == me.attrName and finished != 0)"
        , order_by => "project, attrname"
        })];
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
    $project->enabled(trim($c->request->params->{enabled}) eq "1" ? 1 : 0);

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

        if ($baseName =~ /^\d+$/) { # numeric base name is auto-generated, i.e. a new entry
            $jobset = $project->jobsets->create(
                { name => $jobsetName
                , description => trim $c->request->params->{"jobset-$baseName-description"}
                , nixexprpath => $nixExprPath
                , nixexprinput => $nixExprInput
                });
        } else { # it's an existing jobset
            $jobset = ($project->jobsets->search({name => $baseName}))[0];
            die unless defined $jobset;
            $jobset->name($jobsetName);
            $jobset->description(trim $c->request->params->{"jobset-$baseName-description"});
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
                $inputType eq "string" || $inputType eq "path";

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
                $input->jobsetinputalts->create({altnr => $altnr++, value => trim $value});
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
    my ( $self, $c, $projectName, $subcommand ) = @_;
    $c->stash->{template} = 'project.tt';
    
    (my $project) = $c->model('DB::Projects')->search({ name => $projectName });
    return error($c, "Project $projectName doesn't exist.") if !defined $project;

    my $isPosted = $c->request->method eq "POST";

    $subcommand = "" unless defined $subcommand;

    if ($subcommand eq "edit") {
        $c->stash->{edit} = 1;
    } elsif ($subcommand eq "submit" && $isPosted) {
        $c->model('DB')->schema->txn_do(sub {
            updateProject($c, $project);
        });
        return $c->res->redirect($c->uri_for("/project", trim $c->request->params->{name}));
    } elsif ($subcommand eq "delete" && $isPosted) {
        $c->model('DB')->schema->txn_do(sub {
            $project->delete;
        });
        return $c->res->redirect($c->uri_for("/"));
    } elsif ($subcommand eq "") {
    } else {
        return error($c, "Unknown subcommand $subcommand.");
    }

    $c->stash->{curProject} = $project;
    
    $c->stash->{finishedBuilds} = $c->model('DB::Builds')->search(
        {project => $projectName, finished => 1});
        
    $c->stash->{succeededBuilds} = $c->model('DB::Builds')->search(
        {project => $projectName, finished => 1, buildStatus => 0},
        {join => 'resultInfo'});
        
    $c->stash->{scheduledBuilds} = $c->model('DB::Builds')->search(
        {project => $projectName, finished => 0});
        
    $c->stash->{busyBuilds} = $c->model('DB::Builds')->search(
        {project => $projectName, finished => 0, busy => 1},
        {join => 'schedulingInfo'});
        
    $c->stash->{totalBuildTime} = $c->model('DB::Builds')->search(
        {project => $projectName},
        {join => 'resultInfo', select => {sum => 'stoptime - starttime'}, as => ['sum']})
        ->first->get_column('sum');
    $c->stash->{totalBuildTime} = 0 unless defined $c->stash->{totalBuildTime};
    
    $c->stash->{jobNames} =
        [$c->model('DB::Builds')->search({project => $projectName}, {select => [{distinct => 'attrname'}], as => ['attrname']})];
}


sub createproject :Local {
    my ( $self, $c, $subcommand ) = @_;

    if (defined $subcommand && $subcommand eq "submit") {
        eval {
            my $projectName = $c->request->params->{name};
            $c->model('DB')->schema->txn_do(sub {
                # Note: $projectName is validated in updateProject,
                # which will abort the transaction if the name isn't
                # valid.
                my $project = $c->model('DB::Projects')->create({name => $projectName, displayname => ""});
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
    my ( $self, $c, $projectName, $jobName ) = @_;
    $c->stash->{template} = 'job.tt';

    (my $project) = $c->model('DB::Projects')->search({ name => $projectName });
    return error($c, "Project $projectName doesn't exist.") if !defined $project;
    $c->stash->{curProject} = $project;

    $c->stash->{jobName} = $jobName;
    $c->stash->{builds} = [$c->model('DB::Builds')->search(
        {finished => 1, project => $projectName, attrName => $jobName},
        {order_by => "timestamp DESC"})];
}


sub default :Path {
    my ( $self, $c ) = @_;
    error($c, "Page not found.");
}


sub build :Local {
    my ( $self, $c, $id ) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    $c->stash->{curProject} = $build->project;

    $c->stash->{template} = 'build.tt';
    $c->stash->{build} = $build;
    $c->stash->{id} = $id;

    $c->stash->{curTime} = time;

    if (!$build->finished && $build->schedulingInfo->busy) {
        my $logfile = $build->schedulingInfo->logfile;
        $c->stash->{logtext} = `cat $logfile`;
    }
}


sub log :Local {
    my ( $self, $c, $id, $logPhase ) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    my $log = $build->buildlogs->find({logphase => $logPhase});
    return error($c, "Build $id doesn't have a log phase named $logPhase.") if !defined $log;
    
    $c->stash->{template} = 'log.tt';
    $c->stash->{id} = $id;
    $c->stash->{log} = $log;

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($log->path);
}


sub nixlog :Local {
    my ( $self, $c, $id, $stepnr ) = @_;

    my $build = getBuild($c, $id);
    return error($c, "Build with ID $id doesn't exist.") if !defined $build;

    my $step = $build->buildsteps->find({stepnr => $stepnr});
    return error($c, "Build $id doesn't have a build step $stepnr.") if !defined $step;

    return error($c, "Build step $stepnr of build $id does not have a log file.") if $step->logfile eq "";
    
    $c->stash->{template} = 'log.tt';
    $c->stash->{id} = $id;
    $c->stash->{step} = $step;

    # !!! should be done in the view (as a TT plugin).
    $c->stash->{logtext} = loadLog($step->logfile);
}


sub loadLog {
    my ($path) = @_;

    # !!! quick hack
    my $pipeline = ($path =~ /.bz2$/ ? "cat $path | bzip2 -d" : "cat $path")
        . " | nix-log2xml | xsltproc xsl/mark-errors.xsl - | xsltproc xsl/log2html.xsl - | tail -n +2";

    return `$pipeline`;
}


sub download :Local {
    my ( $self, $c, $id, $productnr, $filename, @path ) = @_;

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
    my ( $self, $c, $buildId, $productnr ) = @_;

    my $build = getBuild($c, $buildId);
    return error($c, "Build with ID $buildId doesn't exist.") if !defined $build;

    my $product = $build->buildproducts->find({productnr => $productnr});
    return error($c, "Build $buildId doesn't have a product $productnr.") if !defined $product;

    return error($c, "Product is not a Nix build.") if $product->type ne "nix-build";

    return error($c, "Path " . $product->path . " is no longer available.") unless HydraFrontend::Helper::Nix::isValidPath($product->path);

    $c->stash->{current_view} = 'HydraFrontend::View::NixClosure';
    $c->stash->{storePath} = $product->path;
    $c->stash->{name} = $build->nixname;
}


sub end : ActionClass('RenderView') {}


1;

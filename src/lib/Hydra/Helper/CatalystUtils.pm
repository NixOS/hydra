package Hydra::Helper::CatalystUtils;

use strict;
use Exporter;
use Readonly;
use Nix::Store;
use Hydra::Helper::Nix;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getBuild getPreviousBuild getNextBuild getPreviousSuccessfulBuild getBuildStats getChannelData
    error notFound
    requireLogin requireProjectOwner requireAdmin requirePost isAdmin isProjectOwner
    trim
    $pathCompRE $relPathRE $relNameRE $jobNameRE $systemRE
    @buildListColumns
);


# Columns from the Builds table needed to render build lists.
Readonly our @buildListColumns => ('id', 'finished', 'timestamp', 'project', 'jobset', 'job', 'nixname', 'system', 'priority', 'busy', 'buildstatus', 'releasename');


sub getBuild {
    my ($c, $id) = @_;
    my $build = $c->model('DB::Builds')->find($id);
    return $build;
}


sub getPreviousBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $prevBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , 'me.id' =>  { '<' => $build->id } 
      }, {rows => 1, order_by => "me.id DESC"});
    
    return $prevBuild;
}


sub getNextBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $nextBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , 'me.id' =>  { '>' => $build->id } 
      }, {rows => 1, order_by => "me.id ASC"});
    
    return $nextBuild;
}


sub getPreviousSuccessfulBuild {
    my ($c, $build) = @_;
    return undef if !defined $build;

    (my $prevBuild) = $c->model('DB::Builds')->search(
      { finished => 1
      , system => $build->system
      , project => $build->project->name
      , jobset => $build->jobset->name
      , job => $build->job->name
      , buildstatus => 0
      , 'me.id' =>  { '<' => $build->id } 
      }, {rows => 1, order_by => "me.id DESC"});
    
    return $prevBuild;
}


sub getBuildStats {
    my ($c, $builds) = @_;
    
    $c->stash->{finishedBuilds} = $builds->search({finished => 1}) || 0;
    
    $c->stash->{succeededBuilds} = $builds->search({finished => 1, buildStatus => 0}) || 0;
        
    $c->stash->{scheduledBuilds} = $builds->search({finished => 0}) || 0;
        
    $c->stash->{busyBuilds} = $builds->search({finished => 0, busy => 1}) || 0;

    my $res;
    $res = $builds->search({}, {select => {sum => 'stoptime - starttime'}, as => ['sum']})->first;
        
    $c->stash->{totalBuildTime} = defined ($res) ? $res->get_column('sum') : 0 ;

}


sub getChannelData {
    my ($c, $builds) = @_;

    my @builds2 = $builds
	->search_literal("exists (select 1 from buildproducts where build = me.id and type = 'nix-build')")
	->search({}, { columns => [@buildListColumns, 'drvpath', 'outpath', 'description', 'homepage'] });
    
    my @storePaths = ();
    foreach my $build (@builds2) {
        next unless isValidPath($build->outpath);
        if (isValidPath($build->drvpath)) {
            # Adding `drvpath' implies adding `outpath' because of the
            # `--include-outputs' flag passed to `nix-store'.
            push @storePaths, $build->drvpath;
        } else {
	    push @storePaths, $build->outpath;
        }
        my $pkgName = $build->nixname . "-" . $build->system . "-" . $build->id;
        $c->stash->{nixPkgs}->{"${pkgName}.nixpkg"} = {build => $build, name => $pkgName};
        # Put the system type in the manifest (for top-level paths) as
	# a hint to the binary patch generator.  (It shouldn't try to
	# generate patches between builds for different systems.)  It
	# would be nice if Nix stored this info for every path but it
	# doesn't.
	$c->stash->{systemForPath}->{$build->outpath} = $build->system;
    };

    $c->stash->{storePaths} = [@storePaths];
}


sub error {
    my ($c, $msg) = @_;
    $c->error($msg);
    $c->detach; # doesn't return
}


sub notFound {
    my ($c, $msg) = @_;
    $c->response->status(404);
    error($c, $msg);
}


sub requireLogin {
    my ($c) = @_;
    $c->flash->{afterLogin} = $c->request->uri;
    $c->response->redirect($c->uri_for('/login'));
    $c->detach; # doesn't return
}


sub isProjectOwner {
    my ($c, $project) = @_;

    return $c->user_exists && ($c->check_user_roles('admin') || $c->user->username eq $project->owner->username || defined $c->model('DB::ProjectMembers')->find({ project => $project, userName => $c->user->username }));
}


sub requireProjectOwner {
    my ($c, $project) = @_;
    
    requireLogin($c) if !$c->user_exists;

    error($c, "Only the project members or administrators can perform this operation.")
        unless isProjectOwner($c, $project);
}


sub isAdmin {
    my ($c) = @_;

    return $c->user_exists && $c->check_user_roles('admin');
}


sub requireAdmin {
    my ($c) = @_;

    requireLogin($c) if !$c->user_exists;
    
    error($c, "Only administrators can perform this operation.")
        unless isAdmin($c);
}


sub requirePost {
    my ($c) = @_;
    error($c, "Request must be POSTed.") if $c->request->method ne "POST";
}


sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}


# Security checking of filenames.
Readonly our $pathCompRE => "(?:[A-Za-z0-9-\+\._][A-Za-z0-9-\+\._]*)";
Readonly our $relPathRE  => "(?:$pathCompRE(?:/$pathCompRE)*)";
Readonly our $relNameRE  => "(?:[A-Za-z0-9-][A-Za-z0-9-\.]*)";
Readonly our $attrNameRE => "(?:[A-Za-z_][A-Za-z0-9_]*)";
Readonly our $jobNameRE  => "(?:$attrNameRE(?:\\.$attrNameRE)*)";
Readonly our $systemRE   => "(?:[a-z0-9_]+-[a-z0-9_]+)";


1;

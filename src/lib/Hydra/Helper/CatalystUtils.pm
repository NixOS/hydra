package Hydra::Helper::CatalystUtils;

use strict;
use Exporter;
use Readonly;
use Hydra::Helper::Nix;

our @ISA = qw(Exporter);
our @EXPORT = qw(
    getBuild getBuildStats getLatestBuilds getChannelData
    error notFound
    requireLogin requireProjectOwner requireAdmin
    trim
    $pathCompRE $relPathRE
);


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


# Return the latest build for each job.
sub getLatestBuilds {
    my ($c, $jobs, $extraAttrs) = @_;

    my @res = ();

    # !!! this could be done more efficiently.

    foreach my $job (ref $jobs eq "ARRAY" ? @{$jobs} : $jobs->all) {
        foreach my $system ($job->builds->search({}, {select => ['system'], distinct => 1})) {
            my ($build) = $job->builds->search(
                { finished => 1, system => $system->system, %$extraAttrs },
                { join => 'resultInfo', order_by => 'timestamp DESC', rows => 1 });
            push @res, $build if defined $build;
        }
    }

    return [@res];
}


sub getChannelData {
    my ($c, $builds) = @_;
    
    my @storePaths = ();
    foreach my $build (@{$builds}) {
        # !!! better do this in getLatestBuilds with a join.
        next unless $build->buildproducts->find({type => "nix-build"});
        next unless isValidPath($build->outpath);
        push @storePaths, $build->outpath;
        my $pkgName = $build->nixname . "-" . $build->system . "-" . $build->id;
        $c->stash->{nixPkgs}->{"${pkgName}.nixpkg"} = {build => $build, name => $pkgName};
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


sub requireProjectOwner {
    my ($c, $project) = @_;
    
    requireLogin($c) if !$c->user_exists;
    
    error($c, "Only the project owner or administrators can perform this operation.")
        unless $c->check_user_roles('admin') || $c->user->username eq $project->owner->username;
}


sub requireAdmin {
    my ($c) = @_;

    requireLogin($c) if !$c->user_exists;
    
    error($c, "Only administrators can perform this operation.")
        unless $c->check_user_roles('admin');
}


sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}


# Security checking of filenames.
Readonly::Scalar our $pathCompRE => "(?:[A-Za-z0-9-\+][A-Za-z0-9-\+\._]*)";
Readonly::Scalar our $relPathRE  => "(?:$pathCompRE(?:\/$pathCompRE)*)";


1;

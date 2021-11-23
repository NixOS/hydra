package Hydra::View::TT;

use strict;
use warnings;
use base 'Catalyst::View::TT';
use Template::Plugin::HTML;
use Hydra::Helper::Nix;
use Time::Seconds;

__PACKAGE__->config(
    TEMPLATE_EXTENSION => '.tt',
    ENCODING => 'utf-8',
    PRE_CHOMP => 1,
    POST_CHOMP => 1,
    expose_methods => [qw/
    buildLogExists
    buildStepLogExists
    jobExists
    linkToJob
    linkToJobset
    linkToProject
    makeNameLinksForJob
    makeNameLinksForJobset
    makeNameTextForJob
    makeNameTextForJobset
    relativeDuration
    stripSSHUser
    /]);

sub buildLogExists {
    my ($self, $c, $build) = @_;
    return 1 if defined $c->config->{log_prefix};
    my @outPaths = map { $_->path } $build->buildoutputs->all;
    return defined findLog($c, $build->drvpath, @outPaths);
}

sub buildStepLogExists {
    my ($self, $c, $step) = @_;
    return 1 if defined $c->config->{log_prefix};
    my @outPaths = map { $_->path } $step->buildstepoutputs->all;
    return defined findLog($c, $step->drvpath, @outPaths);
}

=head2 relativeDuration

Given an integer of seconds, return an English representation of the
duration as a string.

Arguments:

=over 1

=item C<$seconds>

An integer number of seconds

=back

=cut
sub relativeDuration {
    my ($self, $c, $seconds) = @_;
    return Time::Seconds->new($seconds)->pretty();
}

sub stripSSHUser {
    my ($self, $c, $name) = @_;
    if ($name =~ /^.*@(.*)$/) {
        return $1;
    } else {
        return $name;
    }
}

# Check whether the given job is a member of the most recent jobset
# evaluation.
sub jobExists {
    my ($self, $c, $jobset, $jobName) = @_;
    return defined $jobset->builds->search({ job => $jobName, iscurrent => 1 })->single;
}

=head2 linkToProject

Given a L<Hydra::Schema::Result::Project>, return a link to the project.

Arguments:

=over 3

=item C<$self>
=back

=item C<$c>
Catalyst Context
=back

=item C<$project>

The L<Hydra::Schema::Result::Project> to link to.

=back

=cut
sub linkToProject {
    my ($self, $c, $project) = @_;

    my $html = Template::Plugin::HTML->new();

    my $projectName = $project->name;
    my $escapedProjectName = $html->escape($projectName);

    return '<a href="' . $c->uri_for('/project', $projectName) . '">' . $escapedProjectName . '</a>';
}

=head2 linkToJobset

Given a L<Hydra::Schema::Result::Jobset>, return a link to the jobset
and its project in project:jobset notation.

Arguments:

=over 3

=item C<$self>
=back

=item C<$c>
Catalyst Context
=back

=item C<$jobset>

The L<Hydra::Schema::Result::Jobset> to link to.

=back

=cut
sub linkToJobset {
    my ($self, $c, $jobset) = @_;

    my $html = Template::Plugin::HTML->new();

    my $jobsetName = $jobset->name;
    my $escapedJobsetName = $html->escape($jobsetName);

    return linkToProject($self, $c, $jobset->project) .
           ':<a href="' . $c->uri_for('/jobset', $jobset->project->name, $jobsetName) . '">' . $escapedJobsetName . '</a>';
}

=head2 linkToJobset

Given a L<Hydra::Schema::Result::Jobset> and L<String> Job name, return
a link to the job, jobset, and project in project:jobset:job notation.

Arguments:

=over 4

=item C<$self>
=back

=item C<$c>
Catalyst Context
=back

=item C<$jobset>

The L<Hydra::Schema::Result::Jobset> to link to.
=back

=item C<$jobName>

The L<String> job name to link to.

=back

=cut
sub linkToJob {
    my ($self, $c, $jobset, $jobName) = @_;

    my $html = Template::Plugin::HTML->new();

    my $escapedJobName = $html->escape($jobName);

    return linkToJobset($self, $c, $jobset) .
           ':<a href="' . $c->uri_for('/job', $jobset->project->name, $jobset->name, $jobName) . '">' . $escapedJobName . '</a>';
}

=head2 makeNameLinksForJobset

Given a L<Hydra::Schema::Result::Jobset>, return a link to the jobset's
project and a non-link to the jobset in project:jobset notation.

Arguments:

=over 3

=item C<$self>
=back

=item C<$c>
Catalyst Context
=back

=item C<$jobset>

The L<Hydra::Schema::Result::Jobset> to link to.

=back

=cut
sub makeNameLinksForJobset {
    my ($self, $c, $jobset) = @_;

    my $html = Template::Plugin::HTML->new();

    my $escapedJobsetName = $html->escape($jobset->name);

    return linkToProject($self, $c, $jobset->project) . ':' . $escapedJobsetName;
}

=head2 makeNameLinksForJob

Given a L<Hydra::Schema::Result::Jobset> and L<String> Job name, return
a link to the jobset and project, and a non-link to the job in
project:jobset:job notation.

Arguments:

=over 4

=item C<$self>
=back

=item C<$c>
Catalyst Context
=back

=item C<$jobset>

The L<Hydra::Schema::Result::Jobset> to link to.

=back


=item C<$jobName>

The L<String> job name to link to.

=back

=cut
sub makeNameLinksForJob {
    my ($self, $c, $jobset, $jobName) = @_;

    my $html = Template::Plugin::HTML->new();

    my $escapedJobName = $html->escape($jobName);

    return linkToJobset($self, $c, $jobset) . ':' . $escapedJobName;
}

=head2 makeNameTextForJobset

Given a L<Hydra::Schema::Result::Jobset>, return the project and
jobset in project:jobset notation.

Arguments:

=over 3

=item C<$self>
=back

=item C<$c>
Catalyst Context
=back

=item C<$jobset>

The L<Hydra::Schema::Result::Jobset> to link to.

=back

=cut
sub makeNameTextForJobset {
    my ($self, $c, $jobset) = @_;

    return $jobset->project->name . ":" . $jobset->name;
}

=head2 makeNameTextForJob

Given a L<Hydra::Schema::Result::Jobset> and L<String> Job name, return
the job, jobset, and project in project:jobset:job notation.

Arguments:

=over 4

=item C<$self>
=back

=item C<$c>
Catalyst Context
=back

=item C<$jobset>

The L<Hydra::Schema::Result::Jobset> to link to.

=back


=item C<$jobName>

The L<String> job name to link to.

=back

=cut
sub makeNameTextForJob {
    my ($self, $c, $jobset, $jobName) = @_;

    return $jobset->project->name . ":" . $jobset->name . ":" . $jobName;
}

1;

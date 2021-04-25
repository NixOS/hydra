use feature 'unicode_strings';
use strict;
use Setup;
use Data::Dumper;

use HTTP::Request::Common;
use JSON qw(decode_json);

use Test2::V0;

my %ctx = test_init();

require Hydra::Schema;
require Hydra::Model::DB;

require Catalyst::Test;
Catalyst::Test->import('Hydra');
my $db = Hydra::Model::DB->new;
hydra_setup($db);

my $project = $db->resultset('Projects')->create({name => "tests", displayname => "", owner => "root"});

my $jobset = createBaseJobset("initial", "maintainers.nix", $ctx{jobsdir});

ok(
    evalSucceeds($jobset),
    "Evaluating jobs/maintainers.nix.nix should exit with return code 0"
);
is(
    nrQueuedBuildsForJobset($jobset),
    4,
    "Evaluating jobs/maintainers.nix.nix should result in 3 builds"
);

# The order of queued builds is not stable.
my $simple = 0;
my $none = 0;
my $mixed = 0;
my $old_maintainer_style = 0;
for my $i (1..4) {
    print STDERR request(GET "/build/$i", Accept => 'application/json')->content;
    print STDERR $i;
    my $build = decode_json(request(GET "/build/$i", Accept => 'application/json')->content);
    my @maintainers = @{$build->{maintainers}};
    my @m_sorted = sort @maintainers;

    if ($build->{nixname} eq "simple") {
        is(scalar @maintainers, 2, "Two maintainers for build 'simple'");

        # The API only returns emails currently
        is($m_sorted[0], "bar\@example.org", "Wrong first maintainer");
        is($m_sorted[1], "foo\@example.org", "Wrong second maintainer");
        $simple = 1;
    } elsif ($build->{nixname} eq "none") {
        is(scalar @{$build->{maintainers}}, 0, "No maintainers for build 'none'");
        $none = 1;
    } elsif ($build->{nixname} eq "old_maintainer_style") {
        $old_maintainer_style = 1;
        is(scalar @maintainers, 2, "Two maintainers for build 'old_maintainer_style'");

        is($m_sorted[0], "baz\@example.org", "Wrong first maintainer");
        is($m_sorted[1], "foo\@example.org", "Wrong second maintainer");
    } elsif ($build->{nixname} eq "mixed") {
        $mixed = 1;
        is(scalar @maintainers, 2, "Two maintainers for build 'mixed'");

        is($m_sorted[0], "abc\@example.org", "Wrong first maintainer");
        is($m_sorted[1], "baz\@example.org", "Wrong second maintainer");
    }
}

# Ensure that each build was tested once.
is($simple, 1, "Simple jobset not checked");
is($none, 1, "None jobset not checked");
is($mixed, 1, "mixed jobset not checked");
is($old_maintainer_style, 1, "old_maintainer_style jobset not checked");

my $maintainer_bar = $db->resultset('Maintainer')->find({email => "bar\@example.org"});
ok(defined $maintainer_bar, "Invalid entity");
is($maintainer_bar->github_handle, "bar", "Wrong gh handle for bar\@example.org");

# In the testcase the maintainer `foo@example.org` was referenced twice, once
# with GitHub handle, once without. Ensure that the github handle doesn't get lost.
my $maintainer_foo = $db->resultset('Maintainer')->find({email => "foo\@example.org"});
is($maintainer_foo->github_handle, "foo", "Correct maintainer declared");

done_testing;

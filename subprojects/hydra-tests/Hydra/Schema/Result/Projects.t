use strict;
use warnings;
use Setup;

my %ctx = test_init();

require Hydra::Schema;
use Hydra::ExternalLink;

use Test2::V0;

my $db = $ctx{context}->db();

$db->resultset('Users')->create({ username => 'alice', emailaddress => 'root@invalid.org', password => '!' });

my $project = $db->resultset('Projects')->create({
    name => 'tests',
    displayname => 'Tests',
    owner => 'alice',
});

subtest "an accepted homepage round-trips through the database" => sub {
    $project->update({ homepage => Hydra::ExternalLink->parse("HTTPS://Example.COM/a b") });
    is($project->get_column('homepage'), "https://example.com/a%20b", "stored in canonical form");
    $project->discard_changes;
    isa_ok($project->homepage, ['Hydra::ExternalLink::Accepted'], "read back as accepted");
    is($project->homepage->uri->as_string, "https://example.com/a%20b", "with the same value");
    is($project->as_json->{homepage}, "https://example.com/a%20b", "in JSON");
};

subtest "a stored homepage that does not parse reads back as rejected" => sub {
    # Written directly, bypassing the parser.
    for my $bad ("javascript:alert(1)", "example.com") {
        $project->update({ homepage => $bad });
        $project->discard_changes;
        isa_ok($project->homepage, ['Hydra::ExternalLink::Rejected'], "'$bad' is rejected");
        is($project->homepage->text, $bad, "'$bad' is kept for display");
        is($project->as_json->{homepage}, $bad, "'$bad' in JSON");

        # Writing it back leaves it as it was.
        $project->update({ homepage => $project->homepage });
        is($project->get_column('homepage'), $bad, "'$bad' round-trips");
    }
};

subtest "an empty homepage reads back as absent" => sub {
    for my $empty ("", undef) {
        $project->update({ homepage => $empty });
        $project->discard_changes;
        is($project->homepage, undef, defined $empty ? "''" : "NULL");
        is($project->as_json->{homepage}, "", "in JSON");
    }
};

done_testing;

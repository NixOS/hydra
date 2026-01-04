use strict;
use warnings;
use Setup;
use Test2::V0;
use Test2::Tools::Subtest qw(subtest_streamed);
use HTTP::Request;
use HTTP::Request::Common;
use JSON::MaybeXS qw(decode_json encode_json);
use Digest::SHA qw(hmac_sha256_hex);

# Create webhook configuration
my $github_secret = "github-test-secret-12345";
my $github_secret_alt = "github-alternative-secret";
my $gitea_secret = "gitea-test-secret-abcdef";

# Create a temporary directory first to get the path
use File::Temp;
my $tmpdir = File::Temp->newdir(CLEANUP => 0);
my $tmpdir_path = $tmpdir->dirname;

# Write webhook secrets configuration before creating test context
mkdir "$tmpdir_path/hydra-data";

# Create webhook secrets configuration file
my $webhook_config = qq|
<github>
  secret = $github_secret
  secret = $github_secret_alt
</github>
<gitea>
  secret = $gitea_secret
</gitea>
|;
write_file("$tmpdir_path/hydra-data/webhook-secrets.conf", $webhook_config);
chmod 0600, "$tmpdir_path/hydra-data/webhook-secrets.conf";

# Create test context with webhook configuration using include
my $ctx = test_context(
    tmpdir => $tmpdir,
    hydra_config => qq|
<webhooks>
  Include $tmpdir_path/hydra-data/webhook-secrets.conf
</webhooks>
|
);

# Import Catalyst::Test after test context is set up
require Catalyst::Test;
Catalyst::Test->import('Hydra');

# Create a project and jobset for testing
my $user = $ctx->db()->resultset('Users')->create({
    username => "webhook-test",
    emailaddress => 'webhook-test@example.org',
    password => ''
});

my $project = $ctx->db()->resultset('Projects')->create({
    name => "webhook-test",
    displayname => "webhook-test",
    owner => $user->username
});

my $jobset = $project->jobsets->create({
    name => "test-jobset",
    nixexprinput => "src",
    nixexprpath => "default.nix",
    emailoverride => ""
});

my $jobsetinput = $jobset->jobsetinputs->create({name => "src", type => "git"});
$jobsetinput->jobsetinputalts->create({altnr => 0, value => "https://github.com/owner/repo.git"});

# Create another jobset for Gitea
my $jobset_gitea = $project->jobsets->create({
    name => "test-jobset-gitea",
    nixexprinput => "src",
    nixexprpath => "default.nix",
    emailoverride => ""
});

my $jobsetinput_gitea = $jobset_gitea->jobsetinputs->create({name => "src", type => "git"});
$jobsetinput_gitea->jobsetinputalts->create({altnr => 0, value => "https://gitea.example.com/owner/repo.git"});

subtest "GitHub webhook authentication" => sub {
    my $payload = encode_json({
        repository => {
            owner => { name => "owner" },
            name => "repo"
        }
    });

    subtest "without authentication - properly rejects" => sub {
        my $req = POST '/api/push-github',
            "Content-Type" => "application/json",
            "Content" => $payload;

        my $response = request($req);
        is($response->code, 401, "Unauthenticated request is rejected");

        my $data = decode_json($response->content);
        is($data->{error}, "Missing webhook signature", "Proper error message for missing signature");
    };

    subtest "with valid signature" => sub {
        my $signature = "sha256=" . hmac_sha256_hex($payload, $github_secret);

        my $req = POST '/api/push-github',
            "Content-Type" => "application/json",
            "X-Hub-Signature-256" => $signature,
            "Content" => $payload;

        my $response = request($req);
        is($response->code, 200, "Valid signature is accepted");

        if ($response->code != 200) {
            diag("Error response: " . $response->content);
        }

        my $data = decode_json($response->content);
        is($data->{jobsetsTriggered}, ["webhook-test:test-jobset"], "Jobset was triggered with valid authentication");
    };

    subtest "with invalid signature" => sub {
        my $signature = "sha256=" . hmac_sha256_hex($payload, "wrong-secret");

        my $req = POST '/api/push-github',
            "Content-Type" => "application/json",
            "X-Hub-Signature-256" => $signature,
            "Content" => $payload;

        my $response = request($req);
        is($response->code, 401, "Invalid signature is rejected");

        my $data = decode_json($response->content);
        is($data->{error}, "Invalid webhook signature", "Proper error message for invalid signature");
    };

    subtest "with second valid secret (multiple secrets configured)" => sub {
        my $signature = "sha256=" . hmac_sha256_hex($payload, $github_secret_alt);

        my $req = POST '/api/push-github',
            "Content-Type" => "application/json",
            "X-Hub-Signature-256" => $signature,
            "Content" => $payload;

        my $response = request($req);
        is($response->code, 200, "Second valid secret is accepted");
    };
};

subtest "Gitea webhook authentication" => sub {
    my $payload = encode_json({
        repository => {
            owner => { username => "owner" },
            name => "repo",
            clone_url => "https://gitea.example.com/owner/repo.git"
        }
    });

    subtest "without authentication - properly rejects" => sub {
        my $req = POST '/api/push-gitea',
            "Content-Type" => "application/json",
            "Content" => $payload;

        my $response = request($req);
        is($response->code, 401, "Unauthenticated request is rejected");

        my $data = decode_json($response->content);
        is($data->{error}, "Missing webhook signature", "Proper error message for missing signature");
    };

    subtest "with valid signature" => sub {
        # Note: Gitea doesn't use sha256= prefix
        my $signature = hmac_sha256_hex($payload, $gitea_secret);

        my $req = POST '/api/push-gitea',
            "Content-Type" => "application/json",
            "X-Gitea-Signature" => $signature,
            "Content" => $payload;

        my $response = request($req);
        is($response->code, 200, "Valid signature is accepted");

        if ($response->code != 200) {
            diag("Error response: " . $response->content);
        }

        my $data = decode_json($response->content);
        is($data->{jobsetsTriggered}, ["webhook-test:test-jobset-gitea"], "Jobset was triggered with valid authentication");
    };

    subtest "with invalid signature" => sub {
        my $signature = hmac_sha256_hex($payload, "wrong-secret");

        my $req = POST '/api/push-gitea',
            "Content-Type" => "application/json",
            "X-Gitea-Signature" => $signature,
            "Content" => $payload;

        my $response = request($req);
        is($response->code, 401, "Invalid signature is rejected");

        my $data = decode_json($response->content);
        is($data->{error}, "Invalid webhook signature", "Proper error message for invalid signature");
    };
};

done_testing;

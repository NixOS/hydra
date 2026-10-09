use strict;
use warnings;
use Setup;
use Test2::V0;
use File::Path qw(make_path);
use HTTP::Request::Common;

my $ctx = test_context();

setup_catalyst_test($ctx);

my $hydraData = $ctx->{central_env}->{HYDRA_DATA};
make_path("$hydraData/build-logs/g1");

# A log in its bucket, to show the route still serves real logs.
my $drv = "g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-foo.drv";
write_file("$hydraData/build-logs/g1/" . substr($drv, 2), "the build log\n");

# A file next to build-logs/, where hydra.conf lives by default.
write_file("$hydraData/secret.txt", "some secret\n");

subtest "a real log is served" => sub {
    my $response = request(GET "/log/$drv");
    is($response->code, 200, "the log is found");
    like($response->content, qr/the build log/, "with its contents");
};

subtest "a name that is not a store path cannot escape build-logs/" => sub {
    # `..secret.txt` buckets to `../secret.txt`.
    my $response = request(GET "/log/..secret.txt");
    is($response->code, 404, "is not found");
    unlike($response->content, qr/some secret/, "and does not leak the file");
};

done_testing;

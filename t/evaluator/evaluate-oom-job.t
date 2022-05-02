use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::Exec;

my ($systemdrRes) = captureStdoutStderr(3, (
   "systemd-run", "--user", "--collect", "--scope", "--property", "MemoryMax=25M", "--",
   "true"
));

skip_all("systemd-run does not work in this environment") if($systemdrRes != 0);


my ($res, $stdout, $stderr) = captureStdoutStderr(60,
    (
       "systemd-run", "--user", "--collect", "--scope", "--property", "MemoryMax=25M", "--",
       "hydra-eval-jobs",
         "-I", "/dev/zero",
         "-I", "./t/jobs",
         "./t/jobs/oom.nix"
   )
);

isnt($res, 0, "hydra-eval-jobs exits non-zero");
ok(utf8::decode($stderr), "Stderr output is UTF8-clean");
like(
    $stderr,
    qr/^child process \(\d+?\) killed by signal=9$/m,
    "The stderr record includes a relevant error message"
);

done_testing;

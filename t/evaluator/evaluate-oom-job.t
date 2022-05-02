use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::Exec;

my $sd_res;
eval {
  ($sd_res) = captureStdoutStderr(3, (
    "systemd-run",
      "--user",
      "--collect",
      "--scope",
      "--property",
        "MemoryMax=25M",
    "--",
    "true"
  ));
} or do {
  skip_all("`systemd-run` failed when invoked in this environment");
};
if ($sd_res != 0) { skip_all("`systemd-run` returned non-zero when executing `true` (expected 0)"); }

my ($res, $stdout, $stderr) = captureStdoutStderr(60, (
  "systemd-run",
    "--user",
    "--collect",
    "--scope",
    "--property",
      "MemoryMax=25M",
  "--",
  "hydra-eval-jobs",
    "-I", "/dev/zero",
    "-I", "./t/jobs",
    "./t/jobs/oom.nix"
));

isnt($res, 0, "hydra-eval-jobs exits non-zero");
ok(utf8::decode($stderr), "Stderr output is UTF8-clean");
like(
  $stderr,
  qr/^child process \(\d+?\) killed by signal=9$/m,
  "The stderr record includes a relevant error message"
);

done_testing;

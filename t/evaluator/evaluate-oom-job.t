use strict;
use warnings;
use Setup;
use Test2::V0;
use Hydra::Helper::Exec;

# Ensure that `systemd-run` is
# - Available in the PATH/envionment
# - Accessable to the user executing it
# - Capable of using the command switches we use in our test
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
  # The command failed to execute, likely because `systemd-run` is not present
  # in `PATH`
  skip_all("`systemd-run` failed when invoked in this environment");
};
if ($sd_res != 0) {
  # `systemd-run` executed but `sytemd-run` failed to call `true` and return
  # successfully
  skip_all("`systemd-run` returned non-zero when executing `true` (expected 0)");
}

my $ctx = test_context();

# Contain the memory usage to 25 MegaBytes using `systemd-run`
# Run `hydra-eval-jobs` on test job that will purposefully consume all memory
# available
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
    "-I", $ctx->jobsdir,
    ($ctx->jobsdir . "/oom.nix")
));

isnt($res, 0, "`hydra-eval-jobs` exits non-zero");
ok(utf8::decode($stderr), "Stderr output is UTF8-clean");
like(
  $stderr,
  # Assert error log contains messages added in PR
  # https://github.com/NixOS/hydra/pull/1203
  qr/^child process \(\d+?\) killed by signal=9$/m,
  "The stderr record includes a relevant error message"
);

done_testing;

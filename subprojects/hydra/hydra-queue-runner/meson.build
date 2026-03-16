srcs = files(
  'builder.cc',
  'build-remote.cc',
  'build-result.cc',
  'dispatcher.cc',
  'hydra-queue-runner.cc',
  'nar-extractor.cc',
  'queue-monitor.cc',
)

hydra_queue_runner = executable('hydra-queue-runner',
  'hydra-queue-runner.cc',
  srcs,
  dependencies: [
    libhydra_dep,
    nix_util_dep,
    nix_store_dep,
    nix_main_dep,
    pqxx_dep,
    prom_cpp_core_dep,
    prom_cpp_pull_dep,
  ],
  install: true,
)

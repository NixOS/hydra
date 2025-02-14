srcs = files(
  'hydra-build-step.cc',
)

hydra_build_step = executable('hydra-build-step',
  'hydra-build-step.cc',
  srcs,
  dependencies: [
    libhydra_dep,
    nix_dep,
  ],
  install: true,
)

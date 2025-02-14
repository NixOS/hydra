project('hydra', 'cpp',
  version: files('version.txt'),
  license: 'GPL-3.0',
  default_options: [
    'debug=true',
    'optimization=2',
    'cpp_std=c++20',
  ],
)

nix_store_dep = dependency('nix-store', required: true)
nix_main_dep = dependency('nix-main', required: true)
nix_expr_dep = dependency('nix-expr', required: true)
nix_flake_dep = dependency('nix-flake', required: true)
nix_cmd_dep = dependency('nix-cmd', required: true)

# Nix need extra flags not provided in its pkg-config files.
nix_dep = declare_dependency(
  dependencies: [
    nix_store_dep,
    nix_main_dep,
    nix_expr_dep,
    nix_flake_dep,
    nix_cmd_dep,
  ],
  compile_args: ['-include', 'nix/config.h'],
)

pqxx_dep = dependency('libpqxx', required: true)

prom_cpp_core_dep = dependency('prometheus-cpp-core', required: true)
prom_cpp_pull_dep = dependency('prometheus-cpp-pull', required: true)

mdbook = find_program('mdbook', native: true)
perl = find_program('perl', native: true)

subdir('doc/manual')
subdir('nixos-modules')
subdir('src')
subdir('t')

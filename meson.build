project('hydra', 'cpp',
  version: files('version.txt'),
  license: 'GPL-3.0',
  default_options: [
    'debug=true',
    'optimization=2',
    'cpp_std=c++20',
  ],
)

nix_util_dep = dependency('nix-util', required: true)
nix_store_dep = dependency('nix-store', required: true)
nix_main_dep = dependency('nix-main', required: true)

pqxx_dep = dependency('libpqxx', required: true)

prom_cpp_core_dep = dependency('prometheus-cpp-core', required: true)
prom_cpp_pull_dep = dependency('prometheus-cpp-pull', required: true)

mdbook = find_program('mdbook', native: true)
perl = find_program('perl', native: true)

subdir('doc/manual')
subdir('nixos-modules')
subdir('src')
subdir('t')

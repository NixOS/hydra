# This is just a stub project to include all the others as subprojects
# for development shell purposes

project('hydra-dev-shell', 'cpp',
  version: files('version.txt'),
  license: 'GPL-3.0',
  default_options: [
    'debug=true',
    'optimization=2',
    'cpp_std=c++23',
  ],
)

subproject('hydra')
subproject('hydra-linters')
subproject('hydra-manual')
subproject('nix-perl')

# Build rust workspace (dev build only; in Nix release builds, Rust is built separately)
cargo = find_program('cargo', native: true)
cargo_toml = files('Cargo.toml')

build_type = get_option('buildtype')
if build_type == 'debug'
  cargo_profile = 'debug'
  cargo_build_args = ['build']
else
  cargo_profile = 'release'
  cargo_build_args = ['build', '--release']
endif

rust_build = custom_target(
  'rust-workspace-build',
  input: cargo_toml,
  output: ['build-stamp'],
  command: [
    cargo,
    cargo_build_args,
    '--manifest-path', '@INPUT@',
    '--workspace',
    '--message-format=json-render-diagnostics'
  ],
  build_by_default: true,
  install: false,
)

subproject('hydra-tests')

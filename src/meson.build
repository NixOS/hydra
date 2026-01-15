# Native code
subdir('libhydra')
subdir('hydra-evaluator')

hydra_libexecdir = get_option('libexecdir') / 'hydra'

# Data and interpreted
foreach dir : ['lib', 'root']
  install_subdir(dir,
    install_dir: hydra_libexecdir,
  )
endforeach
subdir('sql')
subdir('ttf')

# Static files for website

hydra_libexecdir_static = hydra_libexecdir / 'root' / 'static'

## Bootstrap

bootstrap_name = 'bootstrap-4.3.1-dist'
bootstrap = custom_target(
  'extract-bootstrap',
  input: 'root' / (bootstrap_name + '.zip'),
  output: bootstrap_name,
  command: ['unzip', '-u', '-d', '@OUTDIR@', '@INPUT@'],
)
custom_target(
  'name-bootstrap',
  input: bootstrap,
  output: 'bootstrap',
  command: ['cp', '-r', '@INPUT@' , '@OUTPUT@'],
  install: true,
  install_dir: hydra_libexecdir_static,
)

## Flot

custom_target(
  'extract-flot',
  input: 'root' / 'flot-0.8.3.zip',
  output: 'flot',
  command: ['unzip', '-u', '-d', '@OUTDIR@', '@INPUT@'],
  install: true,
  install_dir: hydra_libexecdir_static / 'js',
)

## Fontawesome

fontawesome_name = 'fontawesome-free-5.10.2-web'
fontawesome = custom_target(
  'extract-fontawesome',
  input: 'root' / (fontawesome_name + '.zip'),
  output: fontawesome_name,
  command: ['unzip', '-u', '-d', '@OUTDIR@', '@INPUT@'],
)
custom_target(
  'name-fontawesome',
  input: fontawesome,
  output: 'fontawesome',
  command: ['cp', '-r', '@INPUT@' , '@OUTPUT@'],
  install: true,
  install_dir: hydra_libexecdir_static,
)

# Scripts

install_subdir('script',
  install_dir: get_option('bindir'),
  exclude_files: [
    'hydra-dev-server',
  ],
  install_mode: 'rwxr-xr-x',
  strip_directory: true,
)

# Build rust workspace
cargo_toml = files('../Cargo.toml')
workspace_root = '..'

otel_feature = get_option('otel').enabled()

build_type = get_option('buildtype')
if build_type == 'debug'
  cargo_profile = 'debug'
  cargo_build_args = ['build']
else
  cargo_profile = 'release'
  cargo_build_args = ['build', '--release']
endif

if otel_feature
  cargo_build_args += ['--features', 'otel']
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
  depends: [],
)

rust_binaries = {
  'queue-runner': 'hydra-queue-runner-v2',
  'builder': 'hydra-builder-v2',
}

rust_outputs = []
foreach src_bin, dest_bin : rust_binaries
  rust_outputs += custom_target(
    'rust-' + src_bin,
    input: rust_build,
    output: dest_bin,
    command: [
      'cp',
      workspace_root / 'target' / cargo_profile / src_bin,
      '@OUTPUT@'
    ],
    install: true,
    install_dir: get_option('bindir'),
    depends: rust_build,
  )
endforeach

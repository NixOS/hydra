project('hydra',
  version: files('version.txt'),
  license: 'GPL-3.0',
  default_options: [
    'debug=true',
    'optimization=2',
  ],
)

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
#
# The scripts can't run as installed: they need `PERL5LIB`, `HYDRA_HOME` and
# the tools they call on `PATH`, which this build intentionally does not set.
#
# The intended use case is that the packaging of Hydra will instead arrange for
# these things to be appropriately set for each script, and only then put
# things in bin dirs / on the `PATH`. For example, our Nix packaging wraps
# scripts separately, based on what is needed / who calls them, and the
# wrappers are installed in bindir as usual.

install_subdir('script',
  install_dir: hydra_libexecdir / 'script',
  exclude_files: [
    'hydra-dev-server',
  ],
  install_mode: 'rwxr-xr-x',
  strip_directory: true,
)

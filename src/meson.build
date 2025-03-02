# Native code
subdir('libhydra')
subdir('hydra-evaluator')
subdir('hydra-queue-runner')

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
  'name-fontawesome-css',
  input: fontawesome,
  output: 'css',
  command: ['cp', '-r', '@INPUT@/css', '@OUTPUT@'],
  install: true,
  install_dir: hydra_libexecdir_static / 'fontawesome',
)
custom_target(
  'name-fontawesome-webfonts',
  input: fontawesome,
  output: 'webfonts',
  command: ['cp', '-r', '@INPUT@/webfonts', '@OUTPUT@'],
  install: true,
  install_dir: hydra_libexecdir_static / 'fontawesome',
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

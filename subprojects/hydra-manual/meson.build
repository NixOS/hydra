project('hydra-manual',
  version: files('version.txt'),
  meson_version: '>= 1.1',
)

mdbook = find_program('mdbook', native: true)

srcs = files(
  'src/SUMMARY.md',
  'src/about.md',
  'src/api.md',
  'src/configuration.md',
  'src/hacking.md',
  'src/installation.md',
  'src/introduction.md',
  'src/jobs.md',
  'src/monitoring/README.md',
  'src/notifications.md',
  'src/plugins/README.md',
  'src/plugins/RunCommand.md',
  'src/plugins/declarative-projects.md',
  'src/projects.md',
  'src/webhooks.md',
)

manual = custom_target(
  'manual',
  command: [
    mdbook,
    'build',
    meson.project_source_root(),
    '-d', meson.current_build_dir() / 'html'
  ],
  depend_files: srcs,
  output: ['html'],
  build_by_default: true,
)

install_subdir(
  manual.full_path(),
  install_dir: get_option('datadir') / 'doc/hydra',
  strip_directory: true,
)

# Install all SQL files in this directory.
# This includes hydra.sql, test.sql, update-dbix.pl, and all upgrade-*.sql files.
install_subdir('.',
  install_dir: hydra_libexecdir / 'sql',
  strip_directory: true,
  exclude_files: ['meson.build', 'update-dbix-harness.sh'],
)

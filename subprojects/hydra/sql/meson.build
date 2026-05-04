# Install hydra.sql, test.sql, update-dbix.pl, and all upgrade-*.sql migration files.
install_data('hydra.sql', 'test.sql', 'update-dbix.pl',
  install_dir: hydra_libexecdir / 'sql',
)
install_subdir('migrations',
  install_dir: hydra_libexecdir / 'sql',
)

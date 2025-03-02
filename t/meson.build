fs = import('fs')

test('perlcritic',
  perl,
  args: ['-w', files('perlcritic.pl')],
  workdir: meson.project_source_root(),
  timeout: -1,
)

testenv = environment(
  {
    'BZR_HOME': meson.current_build_dir() / 'data',
    'HYDRA_DBI': 'dbi:Pg:dbname=hydra-test-suite;port=6433',
    'HYDRA_DATA': meson.current_build_dir() / 'data',
    'HYDRA_HOME': meson.project_source_root() / 'src',
    'PGHOST': '/tmp',
    'PYTHONPATH': '',

    # libpqxx seems to randomly crash with certain values of MALLOC_PERTURB_,
    # set by default by Meson's test(). Very promising, high quality software.
    'MALLOC_PERTURB_': '0',
  },
)
testenv.prepend('PERL5LIB',
  meson.current_source_dir(),
  meson.project_source_root() / 'src/lib',
  separator: ':'
)
testenv.prepend('PATH',
  fs.parent(find_program('nix').full_path()),
  fs.parent(hydra_evaluator.full_path()),
  fs.parent(hydra_queue_runner.full_path()),
  meson.project_source_root() / 'src/script',
  separator: ':'
)

test('testsuite',
  perl,
  args: ['-I', meson.current_source_dir() / 'lib', '-w', files('test.pl')],
  env: testenv,
  workdir: meson.current_source_dir(),
  timeout: -1,
)

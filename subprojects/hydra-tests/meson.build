project('hydra-tests',
  version: files('version.txt'),
  meson_version: '>= 1.1',
)

fs = import('fs')

perl = find_program('perl', native: true)
nix = find_program('nix')
hydra_evaluator = find_program('hydra-evaluator')
hydra_queue_runner = find_program('hydra-queue-runner')

if meson.is_subproject()
  hydra_source_root = meson.global_source_root()
  hydra_home = hydra_source_root / 'subprojects' / 'hydra'
  hydra_perl5lib = hydra_home / 'lib'
  hydra_scripts = hydra_home / 'script'
else
  hydra_home = get_option('hydra_home')
  hydra_perl5lib = hydra_home / 'lib'
  hydra_scripts = fs.parent(hydra_evaluator.full_path())
endif

testenv = environment(
  {
    'BZR_HOME': meson.current_build_dir() / 'data',
    'HYDRA_DBI': 'dbi:Pg:dbname=hydra-test-suite;port=6433',
    'HYDRA_DATA': meson.current_build_dir() / 'data',
    'HYDRA_HOME': hydra_home,
    'PGHOST': '/tmp',
    'PYTHONPATH': '',

    # libpqxx seems to randomly crash with certain values of MALLOC_PERTURB_,
    # set by default by Meson's test(). Very promising, high quality software.
    'MALLOC_PERTURB_': '0',
  },
)
testenv.prepend('PERL5LIB',
  meson.current_source_dir(),
  hydra_perl5lib,
  separator: ':'
)
testenv.prepend('PATH',
  fs.parent(nix.full_path()),
  fs.parent(hydra_evaluator.full_path()),
  fs.parent(hydra_queue_runner.full_path()),
  hydra_scripts,
  separator: ':'
)

test('testsuite',
  perl,
  args: ['-I', meson.current_source_dir() / 'lib', '-w', files('test.pl')],
  env: testenv,
  workdir: meson.current_source_dir(),
  timeout: -1,
)

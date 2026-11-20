project('hydra-tests',
  version: files('version.txt'),
  meson_version: '>= 1.1',
)

fs = import('fs')

# Only set in the dev build, where these come from sibling subprojects.
dev_perl5lib = []
dev_depends = []

perl = find_program('perl', native: true)
nix = find_program('nix')
curl = find_program('curl')

exe_path = [
  fs.parent(nix.full_path()),
  fs.parent(curl.full_path()),
  meson.current_source_dir() / 'scripts',
]

if meson.is_subproject()
  hydra_source_root = meson.global_source_root()
  hydra_home = hydra_source_root / 'subprojects' / 'hydra'
  hydra_perl5lib = hydra_home / 'lib'
  exe_path += hydra_home / 'script'

  # `nix-perl` from its build tree, which is why it is one of the dev shell's
  # subprojects rather than a prebuilt input.
  nix_perl = subproject('nix-perl')
  dev_perl5lib = [ nix_perl.get_variable('nix_perl_lib_dir') ]
  dev_depends = [ nix_perl.get_variable('nix_perl_store_lib') ]

  # In the dev build, the queue runner is built by cargo in the top-level project
  build_type = get_option('buildtype')
  if build_type == 'debug'
    cargo_profile = 'debug'
  else
    cargo_profile = 'release'
  endif
  exe_path += hydra_source_root / 'target' / cargo_profile
else
  hydra_queue_runner = find_program('hydra-queue-runner')
  hydra_builder = find_program('hydra-builder')
  hydra_evaluator = find_program('hydra-evaluator')
  hydra_init = find_program('hydra-init')
  hydra_notify = find_program('hydra-notify')
  hydra_fetch_input = find_program('hydra-fetch-input')

  hydra_home = get_option('hydra_home')
  hydra_perl5lib = hydra_home / 'lib'

  exe_path += fs.parent(hydra_queue_runner.full_path())
  exe_path += fs.parent(hydra_builder.full_path())
  exe_path += fs.parent(hydra_evaluator.full_path())
  exe_path += fs.parent(hydra_init.full_path())
  exe_path += fs.parent(hydra_notify.full_path())
  exe_path += fs.parent(hydra_fetch_input.full_path())
endif

testenv = environment(
  {
    'HYDRA_HOME': hydra_home,
    'PGHOST': '/tmp',
    'PYTHONPATH': '',

    # libpqxx seems to randomly crash with certain values of MALLOC_PERTURB_,
    # set by default by Meson's test(). Very promising, high quality software.
    'MALLOC_PERTURB_': '0',
  },
)
if meson.is_subproject()
  # The Perl scripts run unwrapped from here, which `HYDRA_TEST_PROGRAM_ENV`
  # (from the dev shell) refers to as `@scripts@`.
  testenv.set('HYDRA_TEST_SCRIPT_DIR', hydra_home / 'script')
endif
testenv.prepend('PERL5LIB',
  meson.current_source_dir(),
  hydra_perl5lib,
  dev_perl5lib,
  separator: ':'
)
foreach p : exe_path
  testenv.prepend('PATH', p)
endforeach

test('testsuite',
  perl,
  args: ['-I', meson.current_source_dir() / 'lib', '-w', files('test.pl')],
  env: testenv,
  workdir: meson.current_source_dir(),
  depends: dev_depends,
  timeout: -1,
)

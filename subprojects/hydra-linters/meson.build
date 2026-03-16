project('hydra-linters',
  version: files('version.txt'),
  meson_version: '>= 1.1',
)

perl = find_program('perl', native: true)

test('perlcritic',
  perl,
  args: ['-w', files('perlcritic.pl')],
  timeout: -1,
)

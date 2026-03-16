# This is just a stub project to include all the others as subprojects
# for development shell purposes

project('hydra-dev-shell', 'cpp',
  version: files('version.txt'),
  license: 'GPL-3.0',
  default_options: [
    'debug=true',
    'optimization=2',
    'cpp_std=c++23',
  ],
)

subproject('hydra')
subproject('hydra-linters')
subproject('hydra-manual')
subproject('hydra-tests')

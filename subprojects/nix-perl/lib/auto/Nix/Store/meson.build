# Build Nix::Store Library
#-------------------------------------------------
# Here rather than beside `Store.pm`, so that the build tree has the layout
# XSLoader looks for, `auto/Nix/Store/Store.so`, as the installed one does.
# Then `lib` in the build tree can go on `PERL5LIB` as it is.
nix_perl_store_lib = library(
  'Store',
  sources : nix_perl_store_cc,
  name_prefix : '',
  prelink : true, # For C++ static initializers
  install : true,
  install_mode : 'rwxr-xr-x',
  install_dir : join_paths(nix_perl_install_dir, 'auto', 'Nix', 'Store'),
  dependencies : nix_perl_store_dep_list,
)

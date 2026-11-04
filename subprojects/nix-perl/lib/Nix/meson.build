# Nix-Perl Scripts
#============================================================================



# Sources
#-------------------------------------------------

nix_perl_store_xs = files('Store.xs')

nix_perl_scripts = files(
  'Store.pm',
  'StorePath.pm',
)

nix_perl_scripts_copy_tgts = []
foreach f : nix_perl_scripts
  nix_perl_scripts_copy_tgts += fs.copyfile(f)
endforeach


# Targets
#---------------------------------------------------

nix_perl_store_cc = custom_target(
  'Store.cc',
  output : 'Store.cc',
  input : nix_perl_store_xs,
  command : [ xsubpp, '@INPUT@', '-output', '@OUTPUT@' ],
)

# Install Scripts
#---------------------------------------------------
install_data(
  nix_perl_scripts,
  install_mode : 'rw-r--r--',
  install_dir : join_paths(nix_perl_install_dir, 'Nix'),
)

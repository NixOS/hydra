SUBDIRS = src doc
if CAN_DO_CHECK
  SUBDIRS += t
endif

BOOTCLEAN_SUBDIRS = $(SUBDIRS)
DIST_SUBDIRS      = $(SUBDIRS)
EXTRA_DIST        = hydra-module.nix

install-data-local: hydra-module.nix
	$(INSTALL) -d $(DESTDIR)$(datadir)/nix
	$(INSTALL_DATA) hydra-module.nix $(DESTDIR)$(datadir)/nix/

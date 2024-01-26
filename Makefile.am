SUBDIRS = src doc
if CAN_DO_CHECK
  SUBDIRS += t
endif

BOOTCLEAN_SUBDIRS = $(SUBDIRS)
DIST_SUBDIRS      = $(SUBDIRS)
EXTRA_DIST        = nixos-modules/hydra.nix

install-data-local: nixos-modules/hydra.nix
	$(INSTALL) -d $(DESTDIR)$(datadir)/nix
	$(INSTALL_DATA) nixos-modules/hydra.nix $(DESTDIR)$(datadir)/nix/hydra-module.nix

TEMPLATES = $(wildcard *.tt)
STATIC = \
  $(wildcard static/images/*) \
  $(wildcard static/css/*) \
  static/js/bootbox.min.js \
  static/js/popper.min.js \
  static/js/common.js \
  static/js/jquery/jquery-3.4.1.min.js \
  static/js/jquery/jquery-ui-1.10.4.min.js

FLOT = flot-0.8.3.zip
BOOTSTRAP = bootstrap-4.3.1-dist.zip

ZIPS = $(FLOT) $(BOOTSTRAP)

EXTRA_DIST = $(TEMPLATES) $(STATIC) $(ZIPS)

hydradir = $(libexecdir)/hydra/root
nobase_hydra_DATA = $(EXTRA_DIST)

all:
	mkdir -p $(srcdir)/static/js
	unzip -u -d $(srcdir)/static $(BOOTSTRAP)
	unzip -u -d $(srcdir)/static/js $(FLOT)

install-data-local: $(ZIPS)
	mkdir -p $(hydradir)/static/js
	cp -prvd $(srcdir)/static/js/* $(hydradir)/static/js
	mkdir -p $(hydradir)/static/bootstrap
	cp -prvd $(srcdir)/static/$(basename $(BOOTSTRAP))/* $(hydradir)/static/bootstrap

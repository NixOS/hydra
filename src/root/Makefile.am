TEMPLATES = $(wildcard *.tt)
STATIC = \
  $(wildcard static/images/*) \
  $(wildcard static/css/*) \
  static/js/bootbox.min.js \
  static/js/common.js

FLOT = flot-0.8.3.zip
JQUERY = jquery-ui-1.8.5.custom.zip
BOOTSTRAP = bootstrap-2.3.1.zip

ZIPS = $(FLOT) $(JQUERY) $(BOOTSTRAP)

EXTRA_DIST = $(TEMPLATES) $(STATIC) $(ZIPS)

hydradir = $(libexecdir)/hydra/root
nobase_hydra_DATA = $(EXTRA_DIST)

all:
	mkdir -p $(srcdir)/static/js
	unzip -u -d $(srcdir)/static/js/jquery $(JQUERY)
	unzip -u -d $(srcdir)/static $(BOOTSTRAP)
	unzip -u -d $(srcdir)/static/js $(FLOT)

install-data-local: $(ZIPS)
	mkdir -p $(hydradir)/static/js
	cp -prvd $(srcdir)/static/js/* $(hydradir)/static/js
	mkdir -p $(hydradir)/static/bootstrap
	cp -prvd $(srcdir)/static/bootstrap/* $(hydradir)/static/bootstrap

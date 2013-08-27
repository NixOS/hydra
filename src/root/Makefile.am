TEMPLATES = $(wildcard *.tt)
STATIC = \
  $(wildcard static/images/*) \
  $(wildcard static/css/*) \
  static/js/bootbox.min.js \
  static/js/common.js

FLOT = flot-0.6.zip
JQUERY = jquery-ui-1.8.5.custom.zip
BOOTSTRAP = bootstrap-3.0.0-dist.zip

ZIPS = $(FLOT) $(JQUERY) $(BOOTSTRAP)

EXTRA_DIST = $(TEMPLATES) $(STATIC) $(ZIPS)

hydradir = $(libexecdir)/hydra/root
nobase_hydra_DATA = $(EXTRA_DIST)

all:
	mkdir -p $(srcdir)/static/js
	unzip -u -d $(srcdir)/static/js/jquery $(JQUERY)
	rm -rf $(srcdir)/static/bootstrap
	unzip -u -d $(srcdir)/static $(BOOTSTRAP)
	mv $(srcdir)/static/dist $(srcdir)/static/bootstrap
	unzip -u -d $(srcdir)/static/js $(FLOT)

install-data-local: $(ZIPS)
	mkdir -p $(hydradir)/static/js
	cp -prvd $(srcdir)/static/js/* $(hydradir)/static/js
	mkdir -p $(hydradir)/static/bootstrap
	cp -prvd $(srcdir)/static/bootstrap/* $(hydradir)/static/bootstrap

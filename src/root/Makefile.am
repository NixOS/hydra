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
FONTAWESOME = fontawesome-free-5.10.2-web.zip

ZIPS = $(FLOT) $(BOOTSTRAP) $(FONTAWESOME)

EXTRA_DIST = $(TEMPLATES) $(STATIC) $(ZIPS)

hydradir = $(libexecdir)/hydra/root
nobase_hydra_DATA = $(EXTRA_DIST)

all:
	mkdir -p $(srcdir)/static/js
	unzip -u -d $(srcdir)/static $(BOOTSTRAP)
	rm -rf $(srcdir)/static/bootstrap
	mv $(srcdir)/static/$(basename $(BOOTSTRAP)) $(srcdir)/static/bootstrap
	unzip -u -d $(srcdir)/static/js $(FLOT)
	unzip -u -d $(srcdir)/static $(FONTAWESOME)
	rm -rf $(srcdir)/static/fontawesome
	mv $(srcdir)/static/$(basename $(FONTAWESOME)) $(srcdir)/static/fontawesome

install-data-local: $(ZIPS)
	mkdir -p $(hydradir)/static/js
	cp -prvd $(srcdir)/static/js/* $(hydradir)/static/js
	mkdir -p $(hydradir)/static/bootstrap
	cp -prvd $(srcdir)/static/bootstrap/* $(hydradir)/static/bootstrap
	mkdir -p $(hydradir)/static/fontawesome/{css,webfonts}
	cp -prvd $(srcdir)/static/fontawesome/css/* $(hydradir)/static/fontawesome/css
	cp -prvd $(srcdir)/static/fontawesome/webfonts/* $(hydradir)/static/fontawesome/webfonts
